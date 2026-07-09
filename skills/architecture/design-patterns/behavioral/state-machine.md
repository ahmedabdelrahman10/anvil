---
name: state-machine-pattern
description: State Machine pattern for managing object states and transitions
category: architecture/design-patterns/behavioral
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# State Machine Pattern

## Overview

The State Machine pattern allows an object to alter its behavior when its
internal state changes. The object will appear to change its class.

## Basic Implementation

```go
package statemachine

import (
	"errors"
	"fmt"
	"time"
)

// ErrInvalidTransition is returned when an operation is illegal for the
// current state.
var ErrInvalidTransition = errors.New("invalid state transition")

// OrderState is one state in the order lifecycle. Each method either advances
// the order or returns an error wrapping ErrInvalidTransition.
type OrderState interface {
	Name() string
	Confirm(order *Order) error
	Ship(order *Order, trackingNumber string) error
	Deliver(order *Order) error
	Cancel(order *Order, reason string) error
}

// OrderEvent records something that happened to an order.
type OrderEvent struct {
	Type           string
	Reason         string
	TrackingNumber string
	Timestamp      time.Time
}

// baseState rejects every transition; concrete states embed it and override
// only the transitions they permit.
type baseState struct{}

func (baseState) Confirm(*Order) error        { return fmt.Errorf("confirm: %w", ErrInvalidTransition) }
func (baseState) Ship(*Order, string) error   { return fmt.Errorf("ship: %w", ErrInvalidTransition) }
func (baseState) Deliver(*Order) error        { return fmt.Errorf("deliver: %w", ErrInvalidTransition) }
func (baseState) Cancel(*Order, string) error { return fmt.Errorf("cancel: %w", ErrInvalidTransition) }

// Concrete States
type pendingState struct{ baseState }

func (pendingState) Name() string { return "pending" }

func (pendingState) Confirm(order *Order) error {
	order.setState(confirmedState{})
	order.addEvent(OrderEvent{Type: "confirmed", Timestamp: time.Now()})
	return nil
}

func (pendingState) Cancel(order *Order, reason string) error {
	order.setState(cancelledState{reason: reason})
	order.addEvent(OrderEvent{Type: "cancelled", Reason: reason, Timestamp: time.Now()})
	return nil
}

type confirmedState struct{ baseState }

func (confirmedState) Name() string { return "confirmed" }

func (confirmedState) Ship(order *Order, trackingNumber string) error {
	order.setTrackingNumber(trackingNumber)
	order.setState(shippedState{})
	order.addEvent(OrderEvent{Type: "shipped", TrackingNumber: trackingNumber, Timestamp: time.Now()})
	return nil
}

func (confirmedState) Cancel(order *Order, reason string) error {
	order.setState(cancelledState{reason: reason})
	order.addEvent(OrderEvent{Type: "cancelled", Reason: reason, Timestamp: time.Now()})
	return nil
}

type shippedState struct{ baseState }

func (shippedState) Name() string { return "shipped" }

func (shippedState) Deliver(order *Order) error {
	order.setState(deliveredState{})
	order.addEvent(OrderEvent{Type: "delivered", Timestamp: time.Now()})
	return nil
}

type deliveredState struct{ baseState }

func (deliveredState) Name() string { return "delivered" }

type cancelledState struct {
	baseState
	reason string
}

func (cancelledState) Name() string { return "cancelled" }

// Order is the context whose behavior changes with its state.
type Order struct {
	ID         string
	CustomerID string
	Items      []OrderItem

	state    OrderState
	events   []OrderEvent
	tracking string
}

func NewOrder(id, customerID string, items []OrderItem) *Order {
	return &Order{ID: id, CustomerID: customerID, Items: items, state: pendingState{}}
}

func (o *Order) setState(s OrderState)           { o.state = s }
func (o *Order) State() string                   { return o.state.Name() }
func (o *Order) setTrackingNumber(number string) { o.tracking = number }
func (o *Order) addEvent(event OrderEvent)       { o.events = append(o.events, event) }

// Delegate to the current state.
func (o *Order) Confirm() error                   { return o.state.Confirm(o) }
func (o *Order) Ship(trackingNumber string) error { return o.state.Ship(o, trackingNumber) }
func (o *Order) Deliver() error                   { return o.state.Deliver(o) }
func (o *Order) Cancel(reason string) error       { return o.state.Cancel(o, reason) }

// Usage
func Example() error {
	order := NewOrder("ORD-001", "CUST-001", items)
	fmt.Println(order.State()) // pending

	if err := order.Confirm(); err != nil {
		return err
	}
	fmt.Println(order.State()) // confirmed

	if err := order.Ship("TRK-12345"); err != nil {
		return err
	}
	fmt.Println(order.State()) // shipped

	if err := order.Deliver(); err != nil {
		return err
	}
	fmt.Println(order.State()) // delivered

	// This returns ErrInvalidTransition:
	// err := order.Cancel("Changed mind")
	return nil
}
```

## Declarative State Machine

```go
package statemachine

import (
	"fmt"
	"time"
)

// Transition describes moving to Target when an event fires, optionally gated
// by Guard and running Action during the move.
type Transition[S comparable, C any] struct {
	Target S
	Guard  func(ctx *C) bool
	Action func(ctx *C)
}

// StateConfig is the behavior of one state: its outgoing transitions and
// entry/exit hooks.
type StateConfig[S comparable, E comparable, C any] struct {
	On      map[E]Transition[S, C]
	OnEntry func(ctx *C)
	OnExit  func(ctx *C)
}

// Config is a full machine definition — the transition table. Preferring the
// table over per-state objects keeps transitions deterministic and testable.
type Config[S comparable, E comparable, C any] struct {
	Initial S
	States  map[S]StateConfig[S, E, C]
}

// StateMachine drives a Config over a mutable context.
type StateMachine[S comparable, E comparable, C any] struct {
	config  Config[S, E, C]
	current S
	context *C
}

func NewStateMachine[S comparable, E comparable, C any](config Config[S, E, C], initialContext C) *StateMachine[S, E, C] {
	m := &StateMachine[S, E, C]{
		config:  config,
		current: config.Initial,
		context: &initialContext,
	}
	m.executeEntry(m.current)
	return m
}

func (m *StateMachine[S, E, C]) State() S    { return m.current }
func (m *StateMachine[S, E, C]) Context() *C { return m.context }

// Send applies an event. It reports whether the event caused a transition.
func (m *StateMachine[S, E, C]) Send(event E) bool {
	transition, ok := m.config.States[m.current].On[event]
	if !ok {
		return false // event not valid in current state
	}
	if transition.Guard != nil && !transition.Guard(m.context) {
		return false
	}

	m.executeExit(m.current)
	if transition.Action != nil {
		transition.Action(m.context)
	}
	m.current = transition.Target
	m.executeEntry(m.current)
	return true
}

func (m *StateMachine[S, E, C]) executeEntry(state S) {
	if hook := m.config.States[state].OnEntry; hook != nil {
		hook(m.context)
	}
}

func (m *StateMachine[S, E, C]) executeExit(state S) {
	if hook := m.config.States[state].OnExit; hook != nil {
		hook(m.context)
	}
}

// Order states and events as typed string constants.
type OrderStatus string

const (
	StatusPending   OrderStatus = "pending"
	StatusConfirmed OrderStatus = "confirmed"
	StatusShipped   OrderStatus = "shipped"
	StatusDelivered OrderStatus = "delivered"
	StatusCancelled OrderStatus = "cancelled"
)

type OrderCommand string

const (
	EventConfirm OrderCommand = "CONFIRM"
	EventShip    OrderCommand = "SHIP"
	EventDeliver OrderCommand = "DELIVER"
	EventCancel  OrderCommand = "CANCEL"
)

// OrderContext is the machine's mutable context.
type OrderContext struct {
	OrderID        string
	TrackingNumber string
	CancelReason   string
}

// orderMachine builds the transition table. A constructor func avoids a mutable
// package global.
func orderMachine() Config[OrderStatus, OrderCommand, OrderContext] {
	return Config[OrderStatus, OrderCommand, OrderContext]{
		Initial: StatusPending,
		States: map[OrderStatus]StateConfig[OrderStatus, OrderCommand, OrderContext]{
			StatusPending: {
				On: map[OrderCommand]Transition[OrderStatus, OrderContext]{
					EventConfirm: {Target: StatusConfirmed},
					EventCancel: {
						Target: StatusCancelled,
						Action: func(ctx *OrderContext) { ctx.CancelReason = "Cancelled while pending" },
					},
				},
				OnEntry: func(ctx *OrderContext) { fmt.Printf("Order %s is pending\n", ctx.OrderID) },
			},
			StatusConfirmed: {
				On: map[OrderCommand]Transition[OrderStatus, OrderContext]{
					EventShip: {
						Target: StatusShipped,
						Action: func(ctx *OrderContext) { ctx.TrackingNumber = fmt.Sprintf("TRK-%d", time.Now().UnixNano()) },
					},
					EventCancel: {Target: StatusCancelled},
				},
				OnEntry: func(ctx *OrderContext) { fmt.Printf("Order %s confirmed\n", ctx.OrderID) },
			},
			StatusShipped: {
				On: map[OrderCommand]Transition[OrderStatus, OrderContext]{
					EventDeliver: {Target: StatusDelivered},
				},
				OnEntry: func(ctx *OrderContext) { fmt.Printf("Order %s shipped: %s\n", ctx.OrderID, ctx.TrackingNumber) },
			},
			StatusDelivered: {
				OnEntry: func(ctx *OrderContext) { fmt.Printf("Order %s delivered!\n", ctx.OrderID) },
			},
			StatusCancelled: {
				OnEntry: func(ctx *OrderContext) { fmt.Printf("Order %s cancelled\n", ctx.OrderID) },
			},
		},
	}
}

// Usage
func ExampleDeclarative() {
	machine := NewStateMachine(orderMachine(), OrderContext{OrderID: "ORD-001"})

	machine.Send(EventConfirm) // pending → confirmed
	machine.Send(EventShip)    // confirmed → shipped
	machine.Send(EventDeliver) // shipped → delivered
	machine.Send(EventCancel)  // returns false - not valid in delivered state
}
```

## XState-Style Machine

```go
package statemachine

import "time"

// Action mutates context in response to an event.
type Action[C any, E any] func(ctx *C, event E)

// HierTransition is a transition in a hierarchical machine. Target may be a
// nested path such as "#order.shipped".
type HierTransition[C any, E any] struct {
	Target  string
	Guard   func(ctx *C, event E) bool
	Actions []Action[C, E]
}

// StateNode is a state that may itself contain child states.
type StateNode[C any, E any] struct {
	Initial string
	Type    string // e.g. "final"
	States  map[string]StateNode[C, E]
	On      map[string]HierTransition[C, E]
	Entry   []Action[C, E]
	Exit    []Action[C, E]
}

// MachineDefinition is a hierarchical machine with nested states.
type MachineDefinition[C any, E any] struct {
	ID      string
	Initial string
	Context C
	States  map[string]StateNode[C, E]
}

// FulfillmentContext is the context for the nested order machine.
type FulfillmentContext struct {
	OrderID     string
	Items       []OrderItem
	ConfirmedAt time.Time
}

// OrderMessage is a typed event carrying a discriminating Type.
type OrderMessage struct {
	Type string
}

// orderMachineDef defines an order machine with nested states.
func orderMachineDef() MachineDefinition[FulfillmentContext, OrderMessage] {
	return MachineDefinition[FulfillmentContext, OrderMessage]{
		ID:      "order",
		Initial: "pending",
		Context: FulfillmentContext{},
		States: map[string]StateNode[FulfillmentContext, OrderMessage]{
			"pending": {
				On: map[string]HierTransition[FulfillmentContext, OrderMessage]{
					"CONFIRM": {
						Target:  "processing",
						Guard:   func(ctx *FulfillmentContext, _ OrderMessage) bool { return len(ctx.Items) > 0 },
						Actions: []Action[FulfillmentContext, OrderMessage]{func(ctx *FulfillmentContext, _ OrderMessage) { ctx.ConfirmedAt = time.Now() }},
					},
					"CANCEL": {Target: "cancelled"},
				},
			},
			"processing": {
				Initial: "payment",
				States: map[string]StateNode[FulfillmentContext, OrderMessage]{
					"payment": {
						On: map[string]HierTransition[FulfillmentContext, OrderMessage]{
							"PAYMENT_SUCCESS": {Target: "fulfillment"},
							"PAYMENT_FAILED":  {Target: "#order.cancelled"},
						},
					},
					"fulfillment": {
						On: map[string]HierTransition[FulfillmentContext, OrderMessage]{
							"SHIPPED": {Target: "#order.shipped"},
						},
					},
				},
			},
			"shipped": {
				On: map[string]HierTransition[FulfillmentContext, OrderMessage]{
					"DELIVERED": {Target: "delivered"},
					"RETURNED":  {Target: "returned"},
				},
			},
			"delivered": {Type: "final"},
			"cancelled": {Type: "final"},
			"returned":  {Type: "final"},
		},
	}
}
```

## Workflow Engine

```go
package statemachine

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// WorkflowResult is what a step returns.
type WorkflowResult struct {
	Data     map[string]any
	NextStep string // overrides the step's static Next when set
}

// WorkflowStep is one node in the workflow graph.
type WorkflowStep struct {
	ID      string
	Name    string
	Handler func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error)
	Next    string // "" means end
	OnError string
}

// WorkflowDefinition is the static description of a workflow.
type WorkflowDefinition struct {
	ID          string
	Name        string
	InitialStep string
	Steps       map[string]WorkflowStep
}

// WorkflowHistoryEntry records one step execution.
type WorkflowHistoryEntry struct {
	Step        string
	Status      string
	StartedAt   time.Time
	CompletedAt time.Time
	Err         string
}

// WorkflowContext carries data and history through a run.
type WorkflowContext struct {
	WorkflowID  string
	Data        map[string]any
	CurrentStep string
	History     []WorkflowHistoryEntry
}

// WorkflowEngine runs a WorkflowDefinition to completion.
type WorkflowEngine struct {
	definition WorkflowDefinition
}

func NewWorkflowEngine(definition WorkflowDefinition) *WorkflowEngine {
	return &WorkflowEngine{definition: definition}
}

func (e *WorkflowEngine) Start(ctx context.Context, initialData map[string]any) (*WorkflowContext, error) {
	wf := &WorkflowContext{
		WorkflowID:  uuid.NewString(),
		Data:        initialData,
		CurrentStep: e.definition.InitialStep,
	}
	return e.execute(ctx, wf)
}

func (e *WorkflowEngine) execute(ctx context.Context, wf *WorkflowContext) (*WorkflowContext, error) {
	for wf.CurrentStep != "" {
		step, ok := e.definition.Steps[wf.CurrentStep]
		if !ok {
			return wf, fmt.Errorf("unknown step: %s", wf.CurrentStep)
		}

		wf.History = append(wf.History, WorkflowHistoryEntry{
			Step:      step.ID,
			Status:    "running",
			StartedAt: time.Now(),
		})
		last := len(wf.History) - 1

		result, err := step.Handler(ctx, wf)
		if err != nil {
			wf.History[last].Status = "failed"
			wf.History[last].Err = err.Error()
			if step.OnError == "" {
				return wf, fmt.Errorf("step %s: %w", step.ID, err)
			}
			wf.CurrentStep = step.OnError
			continue
		}

		if wf.Data == nil {
			wf.Data = make(map[string]any)
		}
		for k, v := range result.Data {
			wf.Data[k] = v
		}
		wf.History[last].Status = "completed"
		wf.History[last].CompletedAt = time.Now()

		// Determine next step.
		wf.CurrentStep = firstNonEmpty(result.NextStep, step.Next)
	}
	return wf, nil
}

// firstNonEmpty returns the first non-empty string.
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// orderWorkflow defines an order fulfillment workflow.
func orderWorkflow(inventory InventoryService, payments PaymentService, shipping ShippingService, email EmailService, notifier NotificationService) WorkflowDefinition {
	return WorkflowDefinition{
		ID:          "order-fulfillment",
		Name:        "Order Fulfillment Workflow",
		InitialStep: "validate",
		Steps: map[string]WorkflowStep{
			"validate": {
				ID:   "validate",
				Name: "Validate Order",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					items, _ := wf.Data["items"].([]OrderItem)
					if len(items) == 0 {
						return WorkflowResult{}, errors.New("order has no items")
					}
					return WorkflowResult{}, nil
				},
				Next:    "reserve-inventory",
				OnError: "handle-error",
			},
			"reserve-inventory": {
				ID:   "reserve-inventory",
				Name: "Reserve Inventory",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					items, _ := wf.Data["items"].([]OrderItem)
					reservationID, err := inventory.Reserve(ctx, items)
					if err != nil {
						return WorkflowResult{}, fmt.Errorf("reserve inventory: %w", err)
					}
					return WorkflowResult{Data: map[string]any{"reservationId": reservationID}}, nil
				},
				Next:    "process-payment",
				OnError: "handle-error",
			},
			"process-payment": {
				ID:   "process-payment",
				Name: "Process Payment",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					paymentID, err := payments.Process(ctx, wf.Data["paymentInfo"])
					if err != nil {
						return WorkflowResult{}, fmt.Errorf("process payment: %w", err)
					}
					return WorkflowResult{Data: map[string]any{"paymentId": paymentID}}, nil
				},
				Next:    "create-shipment",
				OnError: "rollback-inventory",
			},
			"create-shipment": {
				ID:   "create-shipment",
				Name: "Create Shipment",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					tracking, err := shipping.CreateShipment(ctx, wf.Data)
					if err != nil {
						return WorkflowResult{}, fmt.Errorf("create shipment: %w", err)
					}
					return WorkflowResult{Data: map[string]any{"trackingNumber": tracking}}, nil
				},
				Next: "send-confirmation",
			},
			"send-confirmation": {
				ID:   "send-confirmation",
				Name: "Send Confirmation",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					if err := email.SendOrderConfirmation(ctx, wf.Data); err != nil {
						return WorkflowResult{}, fmt.Errorf("send confirmation: %w", err)
					}
					return WorkflowResult{}, nil
				},
				Next: "", // end of workflow
			},
			"rollback-inventory": {
				ID:   "rollback-inventory",
				Name: "Rollback Inventory",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					reservationID, _ := wf.Data["reservationId"].(string)
					if err := inventory.Release(ctx, reservationID); err != nil {
						return WorkflowResult{}, fmt.Errorf("release inventory: %w", err)
					}
					return WorkflowResult{}, nil
				},
				Next: "handle-error",
			},
			"handle-error": {
				ID:   "handle-error",
				Name: "Handle Error",
				Handler: func(ctx context.Context, wf *WorkflowContext) (WorkflowResult, error) {
					if err := notifier.NotifyAdmin(ctx, wf); err != nil {
						return WorkflowResult{}, fmt.Errorf("notify admin: %w", err)
					}
					return WorkflowResult{}, nil
				},
				Next: "",
			},
		},
	}
}

// Usage
func ExampleWorkflow(ctx context.Context, engine *WorkflowEngine) (*WorkflowContext, error) {
	return engine.Start(ctx, map[string]any{
		"orderId":     "ORD-001",
		"items":       []OrderItem{{ProductID: "PROD-1", Quantity: 2}},
		"paymentInfo": map[string]any{"method": "credit_card", "token": "tok_xxx"},
	})
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Explicit States | All possible states are clearly defined |
| Controlled Transitions | Invalid state changes are prevented |
| Self-Documenting | State diagram documents behavior |
| Testable | Easy to test each state and transition |
| Maintainable | State logic is organized and isolated |

## When to Use

- Objects with distinct behavioral states
- Complex workflows with defined steps
- Game development (AI, game states)
- UI component states
- Order/transaction processing
- Protocol implementations
