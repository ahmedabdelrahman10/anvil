---
name: observer-pattern
description: Observer pattern for event-driven communication
category: architecture/design-patterns/behavioral
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Observer Pattern

## Overview

The Observer pattern defines a one-to-many dependency between objects so
that when one object changes state, all its dependents are notified and
updated automatically.

## Basic Implementation

```go
package observer

import (
	"fmt"
	"math"
	"sync"
)

// Observer reacts to an event of type T.
type Observer[T any] interface {
	Update(event T)
}

// Subject is the observable side: register, remove, and broadcast.
type Subject[T any] interface {
	Subscribe(o Observer[T])
	Unsubscribe(o Observer[T])
	Notify(event T)
}

// EventEmitter is a concrete Subject. It is safe for concurrent use.
type EventEmitter[T any] struct {
	mu        sync.RWMutex
	observers map[Observer[T]]struct{}
}

func NewEventEmitter[T any]() *EventEmitter[T] {
	return &EventEmitter[T]{observers: make(map[Observer[T]]struct{})}
}

func (e *EventEmitter[T]) Subscribe(o Observer[T]) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.observers[o] = struct{}{}
}

func (e *EventEmitter[T]) Unsubscribe(o Observer[T]) {
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.observers, o)
}

func (e *EventEmitter[T]) Notify(event T) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	for o := range e.observers {
		o.Update(event)
	}
}

// StockPrice is the event broadcast to observers.
type StockPrice struct {
	Symbol string
	Price  float64
	Change float64
}

// StockTicker is a Subject specialized to StockPrice via embedding.
type StockTicker struct {
	*EventEmitter[StockPrice]
}

func NewStockTicker() *StockTicker {
	return &StockTicker{EventEmitter: NewEventEmitter[StockPrice]()}
}

func (t *StockTicker) UpdatePrice(symbol string, price, change float64) {
	t.Notify(StockPrice{Symbol: symbol, Price: price, Change: change})
}

// StockDisplay prints every price update.
type StockDisplay struct{}

func (StockDisplay) Update(event StockPrice) {
	sign := ""
	if event.Change > 0 {
		sign = "+"
	}
	fmt.Printf("%s: $%.2f (%s%.1f%%)\n", event.Symbol, event.Price, sign, event.Change)
}

// StockAlert prints only when a move exceeds its threshold.
type StockAlert struct {
	threshold float64
}

func NewStockAlert(threshold float64) *StockAlert {
	return &StockAlert{threshold: threshold}
}

func (a *StockAlert) Update(event StockPrice) {
	if math.Abs(event.Change) > a.threshold {
		fmt.Printf("ALERT: %s moved %.1f%%!\n", event.Symbol, event.Change)
	}
}

// Usage
func Example() {
	ticker := NewStockTicker()
	ticker.Subscribe(StockDisplay{})
	ticker.Subscribe(NewStockAlert(5))

	ticker.UpdatePrice("AAPL", 150.25, 2.5)
	ticker.UpdatePrice("GOOGL", 2750.00, -6.2) // triggers alert
}
```

## Typed Event System

```go
package observer

import (
	"fmt"
	"reflect"
	"sync"
)

// UserChanges captures a partial update to a user.
type UserChanges = map[string]any

// Each event is its own type — the Go analogue of a string-keyed EventMap.
type UserCreated struct {
	UserID string
	Email  string
}

type UserUpdated struct {
	UserID  string
	Changes UserChanges
}

type UserDeleted struct {
	UserID string
}

type OrderPlaced struct {
	OrderID string
	UserID  string
	Total   float64
}

type OrderShipped struct {
	OrderID        string
	TrackingNumber string
}

// EventBus dispatches events to handlers keyed by event type.
type EventBus struct {
	mu       sync.RWMutex
	handlers map[reflect.Type][]handlerEntry
	nextID   int
}

type handlerEntry struct {
	id int
	fn func(event any)
}

func NewEventBus() *EventBus {
	return &EventBus{handlers: make(map[reflect.Type][]handlerEntry)}
}

// Subscribe registers a typed handler and returns an unsubscribe func. The
// generic wrapper keeps handlers type-safe while the bus stores them uniformly.
func Subscribe[T any](bus *EventBus, handler func(event T)) (unsubscribe func()) {
	var zero T
	key := reflect.TypeOf(zero)

	bus.mu.Lock()
	bus.nextID++
	id := bus.nextID
	bus.handlers[key] = append(bus.handlers[key], handlerEntry{
		id: id,
		fn: func(event any) { handler(event.(T)) },
	})
	bus.mu.Unlock()

	return func() {
		bus.mu.Lock()
		defer bus.mu.Unlock()
		entries := bus.handlers[key]
		for i, e := range entries {
			if e.id == id {
				bus.handlers[key] = append(entries[:i], entries[i+1:]...)
				return
			}
		}
	}
}

// SubscribeOnce fires the handler at most once.
func SubscribeOnce[T any](bus *EventBus, handler func(event T)) {
	var unsubscribe func()
	unsubscribe = Subscribe(bus, func(event T) {
		unsubscribe()
		handler(event)
	})
}

// Emit dispatches an event to every handler registered for its type.
func Emit[T any](bus *EventBus, event T) {
	var zero T
	key := reflect.TypeOf(zero)

	bus.mu.RLock()
	entries := append([]handlerEntry(nil), bus.handlers[key]...)
	bus.mu.RUnlock()

	for _, e := range entries {
		e.fn(event)
	}
}

// Usage
func ExampleTyped() {
	bus := NewEventBus()

	// Type-safe subscription.
	Subscribe(bus, func(e UserCreated) {
		fmt.Printf("User %s created with email %s\n", e.UserID, e.Email)
	})
	Subscribe(bus, func(e OrderPlaced) {
		fmt.Printf("Order %s placed for $%.2f\n", e.OrderID, e.Total)
	})

	// Type-safe emission.
	Emit(bus, UserCreated{UserID: "123", Email: "test@example.com"})
	Emit(bus, OrderPlaced{OrderID: "ORD-001", UserID: "123", Total: 99.99})
}
```

## Async Observer Pattern

```go
package observer

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// AsyncObserver handles an event, possibly doing I/O.
type AsyncObserver[T any] interface {
	Handle(ctx context.Context, event T) error
}

// AsyncEventEmitter notifies async observers in parallel or in sequence.
type AsyncEventEmitter[T any] struct {
	mu        sync.RWMutex
	observers map[AsyncObserver[T]]struct{}
}

func NewAsyncEventEmitter[T any]() *AsyncEventEmitter[T] {
	return &AsyncEventEmitter[T]{observers: make(map[AsyncObserver[T]]struct{})}
}

func (e *AsyncEventEmitter[T]) Subscribe(o AsyncObserver[T]) (unsubscribe func()) {
	e.mu.Lock()
	e.observers[o] = struct{}{}
	e.mu.Unlock()
	return func() {
		e.mu.Lock()
		defer e.mu.Unlock()
		delete(e.observers, o)
	}
}

func (e *AsyncEventEmitter[T]) snapshot() []AsyncObserver[T] {
	e.mu.RLock()
	defer e.mu.RUnlock()
	out := make([]AsyncObserver[T], 0, len(e.observers))
	for o := range e.observers {
		out = append(out, o)
	}
	return out
}

// NotifyAll runs observers concurrently; a failing observer is logged, not fatal.
func (e *AsyncEventEmitter[T]) NotifyAll(ctx context.Context, event T) {
	var wg sync.WaitGroup
	for _, o := range e.snapshot() {
		wg.Add(1)
		go func(o AsyncObserver[T]) {
			defer wg.Done()
			if err := o.Handle(ctx, event); err != nil {
				slog.Error("observer failed", "err", err)
			}
		}(o)
	}
	wg.Wait()
}

// NotifySequential runs observers one at a time.
func (e *AsyncEventEmitter[T]) NotifySequential(ctx context.Context, event T) {
	for _, o := range e.snapshot() {
		if err := o.Handle(ctx, event); err != nil {
			slog.Error("observer failed", "err", err)
		}
	}
}

// NotifyWithTimeout bounds each observer with a per-call deadline.
func (e *AsyncEventEmitter[T]) NotifyWithTimeout(ctx context.Context, event T, timeout time.Duration) {
	var wg sync.WaitGroup
	for _, o := range e.snapshot() {
		wg.Add(1)
		go func(o AsyncObserver[T]) {
			defer wg.Done()
			callCtx, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			if err := o.Handle(callCtx, event); err != nil {
				slog.Error("observer failed", "err", err)
			}
		}(o)
	}
	wg.Wait()
}

// Example: order processing with async observers.
type OrderEvent struct {
	Type    string
	OrderID string
	UserID  string
	Items   []OrderItem
}

type InventoryObserver struct {
	inventory InventoryService
}

func (o *InventoryObserver) Handle(ctx context.Context, event OrderEvent) error {
	if event.Type != "order:placed" {
		return nil
	}
	if err := o.inventory.Reserve(ctx, event.OrderID, event.Items); err != nil {
		return fmt.Errorf("reserve inventory for %s: %w", event.OrderID, err)
	}
	return nil
}

type EmailObserver struct {
	email EmailService
}

func (o *EmailObserver) Handle(ctx context.Context, event OrderEvent) error {
	if event.Type != "order:placed" {
		return nil
	}
	if err := o.email.SendOrderConfirmation(ctx, event.UserID, event.OrderID); err != nil {
		return fmt.Errorf("send confirmation for %s: %w", event.OrderID, err)
	}
	return nil
}

type AnalyticsObserver struct {
	analytics AnalyticsService
}

func (o *AnalyticsObserver) Handle(ctx context.Context, event OrderEvent) error {
	if err := o.analytics.Track(ctx, event.Type, event); err != nil {
		return fmt.Errorf("track %s: %w", event.Type, err)
	}
	return nil
}
```

## Pub/Sub Pattern

A more decoupled version delivers over Go channels rather than callbacks —
channels are the concurrency-idiomatic way to fan a stream of events out to
independent consumers, each draining its own channel on its own goroutine.

```go
package observer

import (
	"context"
	"fmt"
	"regexp"
	"sync"
)

// Message is a published payload on a topic.
type Message struct {
	Topic string
	Body  any
}

// PubSub is a decoupled, channel-based broker.
type PubSub struct {
	mu       sync.RWMutex
	subs     map[string][]chan Message
	patterns []patternSub
	buffer   int
}

type patternSub struct {
	re *regexp.Regexp
	ch chan Message
}

func NewPubSub(buffer int) *PubSub {
	return &PubSub{subs: make(map[string][]chan Message), buffer: buffer}
}

// Subscribe returns a receive-only channel for a topic plus an unsubscribe func.
func (p *PubSub) Subscribe(topic string) (<-chan Message, func()) {
	ch := make(chan Message, p.buffer)
	p.mu.Lock()
	p.subs[topic] = append(p.subs[topic], ch)
	p.mu.Unlock()

	return ch, func() {
		p.mu.Lock()
		defer p.mu.Unlock()
		chans := p.subs[topic]
		for i, c := range chans {
			if c == ch {
				p.subs[topic] = append(chans[:i], chans[i+1:]...)
				close(ch)
				return
			}
		}
	}
}

// SubscribePattern matches topics by regular expression.
func (p *PubSub) SubscribePattern(pattern *regexp.Regexp) (<-chan Message, func()) {
	ch := make(chan Message, p.buffer)
	p.mu.Lock()
	p.patterns = append(p.patterns, patternSub{re: pattern, ch: ch})
	p.mu.Unlock()

	return ch, func() {
		p.mu.Lock()
		defer p.mu.Unlock()
		for i, ps := range p.patterns {
			if ps.ch == ch {
				p.patterns = append(p.patterns[:i], p.patterns[i+1:]...)
				close(ch)
				return
			}
		}
	}
}

// Publish delivers a message to exact-topic and matching-pattern subscribers. A
// non-blocking send drops messages to full subscribers instead of stalling.
func (p *PubSub) Publish(topic string, body any) {
	msg := Message{Topic: topic, Body: body}
	p.mu.RLock()
	defer p.mu.RUnlock()

	for _, ch := range p.subs[topic] {
		select {
		case ch <- msg:
		default:
		}
	}
	for _, ps := range p.patterns {
		if ps.re.MatchString(topic) {
			select {
			case ps.ch <- msg:
			default:
			}
		}
	}
}

// Usage
func ExamplePubSub(ctx context.Context) {
	pubsub := NewPubSub(16)

	// Subscribe to a specific topic.
	placed, unsubPlaced := pubsub.Subscribe("orders:placed")
	defer unsubPlaced()
	go func() {
		for msg := range placed {
			fmt.Println("New order:", msg.Body)
		}
	}()

	// Subscribe to a pattern.
	orders, unsubOrders := pubsub.SubscribePattern(regexp.MustCompile(`^orders:`))
	defer unsubOrders()
	go func() {
		for msg := range orders {
			fmt.Printf("Order event on %s: %v\n", msg.Topic, msg.Body)
		}
	}()

	// Publish.
	pubsub.Publish("orders:placed", map[string]any{"orderId": "123", "total": 99.99})
	pubsub.Publish("orders:shipped", map[string]any{"orderId": "123", "tracking": "TRK-456"})
}
```

## React-Style Observable State

```go
package observer

import "sync"

// ObservableState holds a value and notifies listeners on change.
type ObservableState[T any] struct {
	mu        sync.RWMutex
	state     T
	listeners map[int]func(state T)
	nextID    int
}

func NewObservableState[T any](initial T) *ObservableState[T] {
	return &ObservableState[T]{state: initial, listeners: make(map[int]func(T))}
}

func (o *ObservableState[T]) State() T {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.state
}

// SetState applies an update func to the current state, then notifies listeners.
// Go has no struct spread, so the update returns the full next state.
func (o *ObservableState[T]) SetState(update func(prev T) T) {
	o.mu.Lock()
	o.state = update(o.state)
	next := o.state
	listeners := make([]func(T), 0, len(o.listeners))
	for _, l := range o.listeners {
		listeners = append(listeners, l)
	}
	o.mu.Unlock()

	for _, l := range listeners {
		l(next)
	}
}

func (o *ObservableState[T]) Subscribe(listener func(state T)) (unsubscribe func()) {
	o.mu.Lock()
	o.nextID++
	id := o.nextID
	o.listeners[id] = listener
	o.mu.Unlock()

	return func() {
		o.mu.Lock()
		defer o.mu.Unlock()
		delete(o.listeners, id)
	}
}

// Store is a Redux-style store with selector-scoped subscriptions.
type Store[T any] struct {
	mu     sync.RWMutex
	state  T
	subs   map[int]subscription[T]
	nextID int
}

type subscription[T any] struct {
	selector func(state T) any
	notify   func(value any)
	last     any
}

func NewStore[T any](initial T) *Store[T] {
	return &Store[T]{state: initial, subs: make(map[int]subscription[T])}
}

func (s *Store[T]) State() T {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state
}

func (s *Store[T]) Dispatch(reducer func(state T) T) {
	s.mu.Lock()
	s.state = reducer(s.state)
	state := s.state
	s.mu.Unlock()
	s.notifyAll(state)
}

// SubscribeSelector registers a selector-scoped listener that fires only when
// the selected value changes. It returns an unsubscribe func. It is a free
// function because the selected type S is per-subscription.
func SubscribeSelector[T any, S comparable](s *Store[T], selector func(state T) S, listener func(value S)) (unsubscribe func()) {
	s.mu.Lock()
	s.nextID++
	id := s.nextID
	current := selector(s.state)
	s.subs[id] = subscription[T]{
		selector: func(state T) any { return selector(state) },
		notify:   func(value any) { listener(value.(S)) },
		last:     current,
	}
	s.mu.Unlock()

	listener(current) // immediately call with current value
	return func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		delete(s.subs, id)
	}
}

func (s *Store[T]) notifyAll(state T) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, sub := range s.subs {
		value := sub.selector(state)
		if value == sub.last {
			continue
		}
		sub.last = value
		s.subs[id] = sub
		sub.notify(value)
	}
}

// Usage
type AppState struct {
	User          *User
	Cart          []CartItem
	Notifications []Notification
}

func ExampleStore() {
	store := NewStore(AppState{})

	// Subscribe to specific parts of state.
	SubscribeSelector(store, func(s AppState) int { return len(s.Cart) }, func(count int) {
		fmt.Printf("Cart has %d items\n", count)
	})
	SubscribeSelector(store, func(s AppState) *User { return s.User }, func(u *User) {
		fmt.Printf("User changed: %v\n", u)
	})

	// Update state.
	store.Dispatch(func(s AppState) AppState {
		s.Cart = append(s.Cart, CartItem{ProductID: "123", Quantity: 1})
		return s
	})
}
```

## Domain Events

```go
package observer

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

// DomainEvent is something that happened in the domain.
type DomainEvent interface {
	EventType() string
	OccurredOn() time.Time
}

// BaseEvent supplies the OccurredOn timestamp via embedding.
type BaseEvent struct {
	occurredOn time.Time
}

func NewBaseEvent() BaseEvent {
	return BaseEvent{occurredOn: time.Now()}
}

func (e BaseEvent) OccurredOn() time.Time { return e.occurredOn }

// OrderPlacedEvent and OrderShippedEvent are concrete domain events.
type OrderPlacedEvent struct {
	BaseEvent
	OrderID    string
	CustomerID string
	Total      float64
}

func (OrderPlacedEvent) EventType() string { return "OrderPlaced" }

type OrderShippedEvent struct {
	BaseEvent
	OrderID        string
	TrackingNumber string
}

func (OrderShippedEvent) EventType() string { return "OrderShipped" }

// DomainEventDispatcher fans each event out to its registered handlers.
type DomainEventDispatcher struct {
	mu       sync.RWMutex
	handlers map[string][]func(ctx context.Context, event DomainEvent) error
}

func NewDomainEventDispatcher() *DomainEventDispatcher {
	return &DomainEventDispatcher{handlers: make(map[string][]func(context.Context, DomainEvent) error)}
}

// RegisterEventHandler wires a typed handler for one event type.
func RegisterEventHandler[T DomainEvent](d *DomainEventDispatcher, handler func(ctx context.Context, event T) error) {
	var zero T
	eventType := zero.EventType()

	d.mu.Lock()
	defer d.mu.Unlock()
	d.handlers[eventType] = append(d.handlers[eventType], func(ctx context.Context, event DomainEvent) error {
		return handler(ctx, event.(T))
	})
}

// Dispatch runs every handler for an event concurrently, joining their errors.
func (d *DomainEventDispatcher) Dispatch(ctx context.Context, event DomainEvent) error {
	d.mu.RLock()
	handlers := append([]func(context.Context, DomainEvent) error(nil), d.handlers[event.EventType()]...)
	d.mu.RUnlock()
	if len(handlers) == 0 {
		return nil
	}

	var wg sync.WaitGroup
	errs := make([]error, len(handlers))
	for i, h := range handlers {
		wg.Add(1)
		go func(i int, h func(context.Context, DomainEvent) error) {
			defer wg.Done()
			errs[i] = h(ctx, event)
		}(i, h)
	}
	wg.Wait()

	if err := errors.Join(errs...); err != nil {
		return fmt.Errorf("dispatch %s: %w", event.EventType(), err)
	}
	return nil
}

func (d *DomainEventDispatcher) DispatchAll(ctx context.Context, events []DomainEvent) error {
	for _, event := range events {
		if err := d.Dispatch(ctx, event); err != nil {
			return err
		}
	}
	return nil
}

// Order is an aggregate that records domain events as it changes.
type Order struct {
	id         string
	customerID string
	total      float64
	status     string
	tracking   string
	events     []DomainEvent
}

func (o *Order) Place() {
	o.status = "placed"
	o.events = append(o.events, OrderPlacedEvent{
		BaseEvent:  NewBaseEvent(),
		OrderID:    o.id,
		CustomerID: o.customerID,
		Total:      o.total,
	})
}

func (o *Order) Ship(trackingNumber string) {
	o.status = "shipped"
	o.tracking = trackingNumber
	o.events = append(o.events, OrderShippedEvent{
		BaseEvent:      NewBaseEvent(),
		OrderID:        o.id,
		TrackingNumber: trackingNumber,
	})
}

// PullEvents returns the pending events and clears them.
func (o *Order) PullEvents() []DomainEvent {
	events := o.events
	o.events = nil
	return events
}

// Register handlers
func ExampleDomainEvents(email EmailService, analytics AnalyticsService) *DomainEventDispatcher {
	dispatcher := NewDomainEventDispatcher()

	RegisterEventHandler(dispatcher, func(ctx context.Context, e OrderPlacedEvent) error {
		return email.SendOrderConfirmation(ctx, e.CustomerID, e.OrderID)
	})
	RegisterEventHandler(dispatcher, func(ctx context.Context, e OrderPlacedEvent) error {
		return analytics.TrackOrder(ctx, e)
	})
	RegisterEventHandler(dispatcher, func(ctx context.Context, e OrderShippedEvent) error {
		return email.SendShippingNotification(ctx, e.OrderID, e.TrackingNumber)
	})
	return dispatcher
}

// In repository
type OrderRepository struct {
	db         Database
	dispatcher *DomainEventDispatcher
}

func (r *OrderRepository) Save(ctx context.Context, order *Order) error {
	if err := r.db.Save(ctx, order); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	if err := r.dispatcher.DispatchAll(ctx, order.PullEvents()); err != nil {
		return fmt.Errorf("dispatch order events: %w", err)
	}
	return nil
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Loose Coupling | Subjects and observers don't know each other directly |
| Open/Closed | Add observers without modifying subject |
| Broadcast | One notification reaches all interested parties |
| Dynamic | Add/remove observers at runtime |

## When to Use

- State changes should trigger multiple actions
- Decoupled event-driven systems
- UI updates from model changes
- Cross-cutting concerns (logging, analytics)
- Implementing message queues
