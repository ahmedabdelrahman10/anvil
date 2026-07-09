---
name: command-pattern
description: Command pattern for encapsulating requests as objects
category: architecture/design-patterns/behavioral
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Command Pattern

## Overview

The Command pattern encapsulates a request as an object, letting you
parameterize clients with different requests, queue or log requests,
and support undoable operations.

## Basic Implementation

```go
package command

import (
	"context"
	"fmt"
)

// CreateUserData / UserData / User are the domain types the commands act on.
type CreateUserData struct {
	Email string
	Name  string
}

type UserData struct {
	Email string
	Name  string
}

type User struct {
	ID   string
	Data UserData
}

func (u *User) CreateData() CreateUserData {
	return CreateUserData{Email: u.Data.Email, Name: u.Data.Name}
}

// UserService is a small consumer-side interface: the commands depend only on
// the behavior they use (accept interfaces, return structs).
type UserService interface {
	Create(ctx context.Context, data CreateUserData) (*User, error)
	Update(ctx context.Context, id string, updates UserData) error
	Delete(ctx context.Context, id string) error
	FindByID(ctx context.Context, id string) (*User, error)
}

// Command encapsulates a request as an object.
type Command interface {
	Execute(ctx context.Context) error
	Name() string
}

// Undoer is an optional capability implemented only by reversible commands; the
// invoker type-asserts to it rather than forcing every Command to be reversible.
type Undoer interface {
	Undo(ctx context.Context) error
}

// CreateUserCommand creates a user and remembers its ID so it can be undone.
type CreateUserCommand struct {
	users         UserService
	data          CreateUserData
	createdUserID string
}

func NewCreateUserCommand(users UserService, data CreateUserData) *CreateUserCommand {
	return &CreateUserCommand{users: users, data: data}
}

func (c *CreateUserCommand) Execute(ctx context.Context) error {
	user, err := c.users.Create(ctx, c.data)
	if err != nil {
		return fmt.Errorf("create user %s: %w", c.data.Email, err)
	}
	c.createdUserID = user.ID
	return nil
}

func (c *CreateUserCommand) Undo(ctx context.Context) error {
	if c.createdUserID == "" {
		return nil
	}
	if err := c.users.Delete(ctx, c.createdUserID); err != nil {
		return fmt.Errorf("undo create user %s: %w", c.createdUserID, err)
	}
	return nil
}

func (c *CreateUserCommand) Name() string {
	return fmt.Sprintf("CreateUser: %s", c.data.Email)
}

// UpdateUserCommand updates a user, capturing prior state for undo.
type UpdateUserCommand struct {
	users        UserService
	userID       string
	updates      UserData
	previousData *UserData
}

func NewUpdateUserCommand(users UserService, userID string, updates UserData) *UpdateUserCommand {
	return &UpdateUserCommand{users: users, userID: userID, updates: updates}
}

func (c *UpdateUserCommand) Execute(ctx context.Context) error {
	user, err := c.users.FindByID(ctx, c.userID)
	if err != nil {
		return fmt.Errorf("load user %s for update: %w", c.userID, err)
	}
	prev := user.Data
	c.previousData = &prev

	if err := c.users.Update(ctx, c.userID, c.updates); err != nil {
		return fmt.Errorf("update user %s: %w", c.userID, err)
	}
	return nil
}

func (c *UpdateUserCommand) Undo(ctx context.Context) error {
	if c.previousData == nil {
		return nil
	}
	if err := c.users.Update(ctx, c.userID, *c.previousData); err != nil {
		return fmt.Errorf("undo update user %s: %w", c.userID, err)
	}
	return nil
}

func (c *UpdateUserCommand) Name() string {
	return fmt.Sprintf("UpdateUser: %s", c.userID)
}

// DeleteUserCommand deletes a user, keeping the record so it can be restored.
type DeleteUserCommand struct {
	users       UserService
	userID      string
	deletedUser *User
}

func NewDeleteUserCommand(users UserService, userID string) *DeleteUserCommand {
	return &DeleteUserCommand{users: users, userID: userID}
}

func (c *DeleteUserCommand) Execute(ctx context.Context) error {
	user, err := c.users.FindByID(ctx, c.userID)
	if err != nil {
		return fmt.Errorf("load user %s for delete: %w", c.userID, err)
	}
	c.deletedUser = user

	if err := c.users.Delete(ctx, c.userID); err != nil {
		return fmt.Errorf("delete user %s: %w", c.userID, err)
	}
	return nil
}

func (c *DeleteUserCommand) Undo(ctx context.Context) error {
	if c.deletedUser == nil {
		return nil
	}
	if _, err := c.users.Create(ctx, c.deletedUser.CreateData()); err != nil {
		return fmt.Errorf("undo delete user %s: %w", c.userID, err)
	}
	return nil
}

func (c *DeleteUserCommand) Name() string {
	return fmt.Sprintf("DeleteUser: %s", c.userID)
}

// Invoker executes commands and maintains undo/redo history.
type Invoker struct {
	history []Command
	undone  []Command
}

func NewInvoker() *Invoker {
	return &Invoker{}
}

func (in *Invoker) Execute(ctx context.Context, cmd Command) error {
	if err := cmd.Execute(ctx); err != nil {
		return fmt.Errorf("execute %s: %w", cmd.Name(), err)
	}
	in.history = append(in.history, cmd)
	in.undone = in.undone[:0] // clear redo stack
	return nil
}

func (in *Invoker) Undo(ctx context.Context) error {
	if len(in.history) == 0 {
		return nil
	}
	cmd := in.history[len(in.history)-1]
	in.history = in.history[:len(in.history)-1]

	undoer, ok := cmd.(Undoer)
	if !ok {
		return nil
	}
	if err := undoer.Undo(ctx); err != nil {
		return fmt.Errorf("undo %s: %w", cmd.Name(), err)
	}
	in.undone = append(in.undone, cmd)
	return nil
}

func (in *Invoker) Redo(ctx context.Context) error {
	if len(in.undone) == 0 {
		return nil
	}
	cmd := in.undone[len(in.undone)-1]
	in.undone = in.undone[:len(in.undone)-1]

	if err := cmd.Execute(ctx); err != nil {
		return fmt.Errorf("redo %s: %w", cmd.Name(), err)
	}
	in.history = append(in.history, cmd)
	return nil
}

func (in *Invoker) History() []string {
	names := make([]string, len(in.history))
	for i, cmd := range in.history {
		names[i] = cmd.Name()
	}
	return names
}

// Usage
func Example(ctx context.Context, users UserService) error {
	invoker := NewInvoker()

	if err := invoker.Execute(ctx, NewCreateUserCommand(users, CreateUserData{Email: "john@example.com"})); err != nil {
		return err
	}
	if err := invoker.Execute(ctx, NewUpdateUserCommand(users, "user-1", UserData{Name: "John Doe"})); err != nil {
		return err
	}

	fmt.Println(invoker.History())
	// [CreateUser: john@example.com UpdateUser: user-1]

	_ = invoker.Undo(ctx) // reverts UpdateUser
	_ = invoker.Undo(ctx) // reverts CreateUser (deletes user)
	_ = invoker.Redo(ctx) // re-creates user
	return nil
}
```

## Command Queue

```go
package command

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

// QueueOptions configures how a command is enqueued.
type QueueOptions struct {
	Priority    int
	ScheduledAt time.Time // zero value = run immediately
	MaxRetries  int
}

// queuedCommand wraps a Command with scheduling and retry metadata.
type queuedCommand struct {
	Command
	id          string
	priority    int
	scheduledAt time.Time
	maxRetries  int
	retryCount  int
}

// CommandQueue runs commands asynchronously, honoring priority, scheduling, and
// per-command retries. A single worker goroutine drains the queue.
type CommandQueue struct {
	mu         sync.Mutex
	queue      []*queuedCommand
	processing bool
}

func NewCommandQueue() *CommandQueue {
	return &CommandQueue{}
}

func (q *CommandQueue) Enqueue(ctx context.Context, cmd Command, opts QueueOptions) string {
	maxRetries := opts.MaxRetries
	if maxRetries == 0 {
		maxRetries = 3
	}
	qc := &queuedCommand{
		Command:     cmd,
		id:          uuid.NewString(),
		priority:    opts.Priority,
		scheduledAt: opts.ScheduledAt,
		maxRetries:  maxRetries,
	}

	q.mu.Lock()
	q.queue = append(q.queue, qc)
	sort.SliceStable(q.queue, func(i, j int) bool {
		return q.queue[i].priority > q.queue[j].priority
	})
	start := !q.processing
	if start {
		q.processing = true
	}
	q.mu.Unlock()

	if start {
		go q.process(ctx)
	}
	return qc.id
}

func (q *CommandQueue) process(ctx context.Context) {
	for {
		q.mu.Lock()
		if len(q.queue) == 0 {
			q.processing = false
			q.mu.Unlock()
			return
		}
		qc := q.queue[0]
		q.queue = q.queue[1:]
		q.mu.Unlock()

		// Not due yet: requeue and wait.
		if !qc.scheduledAt.IsZero() && qc.scheduledAt.After(time.Now()) {
			q.mu.Lock()
			q.queue = append(q.queue, qc)
			q.mu.Unlock()
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
			continue
		}

		if err := qc.Execute(ctx); err != nil {
			qc.retryCount++
			if qc.retryCount < qc.maxRetries {
				slog.Warn("command retry", "name", qc.Name(), "attempt", qc.retryCount, "max", qc.maxRetries)
				q.mu.Lock()
				q.queue = append(q.queue, qc)
				q.mu.Unlock()
				continue
			}
			slog.Error("command failed", "name", qc.Name(), "retries", qc.maxRetries, "err", err)
			continue
		}
		slog.Info("command executed", "name", qc.Name())
	}
}

// Usage
func ExampleQueue(ctx context.Context, q *CommandQueue) {
	q.Enqueue(ctx, NewSendEmailCommand(emailService, emailData), QueueOptions{Priority: 10})
	q.Enqueue(ctx, NewProcessPaymentCommand(paymentService, paymentData), QueueOptions{Priority: 20})
	q.Enqueue(ctx, NewGenerateReportCommand(reportService), QueueOptions{
		Priority:    5,
		ScheduledAt: time.Now().Add(time.Minute), // 1 minute later
	})
}
```

## Macro Commands (Composite)

```go
package command

import (
	"context"
	"fmt"
)

// MacroCommand runs several commands as one, undoing them in reverse order.
type MacroCommand struct {
	commands []Command
	name     string
}

func NewMacroCommand(name string, commands ...Command) *MacroCommand {
	return &MacroCommand{commands: commands, name: name}
}

func (m *MacroCommand) Execute(ctx context.Context) error {
	for _, cmd := range m.commands {
		if err := cmd.Execute(ctx); err != nil {
			return fmt.Errorf("macro %s step %s: %w", m.name, cmd.Name(), err)
		}
	}
	return nil
}

func (m *MacroCommand) Undo(ctx context.Context) error {
	// Undo in reverse order.
	for i := len(m.commands) - 1; i >= 0; i-- {
		undoer, ok := m.commands[i].(Undoer)
		if !ok {
			continue
		}
		if err := undoer.Undo(ctx); err != nil {
			return fmt.Errorf("macro %s undo %s: %w", m.name, m.commands[i].Name(), err)
		}
	}
	return nil
}

func (m *MacroCommand) Name() string {
	return m.name
}

// Usage: create order workflow
func ExampleMacro(ctx context.Context) error {
	createOrder := NewMacroCommand("CreateOrder",
		NewValidateInventoryCommand(inventoryService, orderItems),
		NewReserveInventoryCommand(inventoryService, orderItems),
		NewProcessPaymentCommand(paymentService, paymentData),
		NewCreateOrderRecordCommand(orderService, orderData),
		NewSendConfirmationEmailCommand(emailService, customerEmail),
	)

	invoker := NewInvoker()
	if err := invoker.Execute(ctx, createOrder); err != nil {
		return err
	}

	// Undo entire workflow.
	return invoker.Undo(ctx)
}
```

## Command with Result

```go
package command

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// ResultCommand is a command that produces a typed result.
type ResultCommand[T any] interface {
	Execute(ctx context.Context) (T, error)
	Name() string
}

// CreateOrderCommand creates an order and returns it.
type CreateOrderCommand struct {
	orders OrderService
	data   CreateOrderData
}

func NewCreateOrderCommand(orders OrderService, data CreateOrderData) *CreateOrderCommand {
	return &CreateOrderCommand{orders: orders, data: data}
}

func (c *CreateOrderCommand) Execute(ctx context.Context) (*Order, error) {
	order, err := c.orders.Create(ctx, c.data)
	if err != nil {
		return nil, fmt.Errorf("create order for %s: %w", c.data.CustomerID, err)
	}
	return order, nil
}

func (c *CreateOrderCommand) Name() string {
	return fmt.Sprintf("CreateOrder: %s", c.data.CustomerID)
}

// HandleCommand runs a result-bearing command with timing and logging. It is a
// free function because Go methods cannot declare their own type parameters.
func HandleCommand[T any](ctx context.Context, cmd ResultCommand[T]) (T, error) {
	slog.Info("executing command", "name", cmd.Name())
	start := time.Now()

	result, err := cmd.Execute(ctx)
	if err != nil {
		slog.Error("command failed", "name", cmd.Name(), "err", err)
		return result, fmt.Errorf("handle %s: %w", cmd.Name(), err)
	}
	slog.Info("command completed", "name", cmd.Name(), "took", time.Since(start))
	return result, nil
}

// Usage
func ExampleResult(ctx context.Context, orders OrderService, data CreateOrderData) (*Order, error) {
	return HandleCommand[*Order](ctx, NewCreateOrderCommand(orders, data))
}
```

## CQRS Commands

```go
package command

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// CQRSCommand carries metadata and identifies its own type.
type CQRSCommand interface {
	CommandType() string
}

// BaseCommand supplies common metadata via embedding.
type BaseCommand struct {
	CommandID string
	Timestamp time.Time
}

func NewBaseCommand() BaseCommand {
	return BaseCommand{CommandID: uuid.NewString(), Timestamp: time.Now()}
}

// PlaceOrderCommand and CancelOrderCommand embed BaseCommand.
type PlaceOrderCommand struct {
	BaseCommand
	CustomerID      string
	Items           []OrderItem
	ShippingAddress Address
}

func (PlaceOrderCommand) CommandType() string { return "PlaceOrder" }

type CancelOrderCommand struct {
	BaseCommand
	OrderID string
	Reason  string
}

func (CancelOrderCommand) CommandType() string { return "CancelOrder" }

// PlaceOrderHandler handles PlaceOrderCommand.
type PlaceOrderHandler struct {
	orders    OrderRepository
	inventory InventoryService
	payments  PaymentService
}

func NewPlaceOrderHandler(orders OrderRepository, inventory InventoryService, payments PaymentService) *PlaceOrderHandler {
	return &PlaceOrderHandler{orders: orders, inventory: inventory, payments: payments}
}

func (h *PlaceOrderHandler) Handle(ctx context.Context, cmd PlaceOrderCommand) error {
	if err := h.inventory.ValidateAvailability(ctx, cmd.Items); err != nil {
		return fmt.Errorf("validate inventory: %w", err)
	}
	order := NewOrder(cmd.CustomerID, cmd.Items, cmd.ShippingAddress)
	if err := h.payments.ProcessPayment(ctx, order); err != nil {
		return fmt.Errorf("process payment: %w", err)
	}
	if err := h.orders.Save(ctx, order); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	return nil
}

// CancelOrderHandler handles CancelOrderCommand.
type CancelOrderHandler struct {
	orders   OrderRepository
	payments PaymentService
}

func NewCancelOrderHandler(orders OrderRepository, payments PaymentService) *CancelOrderHandler {
	return &CancelOrderHandler{orders: orders, payments: payments}
}

func (h *CancelOrderHandler) Handle(ctx context.Context, cmd CancelOrderCommand) error {
	order, err := h.orders.FindByID(ctx, cmd.OrderID)
	if err != nil {
		return fmt.Errorf("load order %s: %w", cmd.OrderID, err)
	}
	if err := order.Cancel(cmd.Reason); err != nil {
		return fmt.Errorf("cancel order %s: %w", cmd.OrderID, err)
	}
	if err := h.payments.Refund(ctx, order.PaymentID); err != nil {
		return fmt.Errorf("refund order %s: %w", cmd.OrderID, err)
	}
	return h.orders.Save(ctx, order)
}

// CommandBus dispatches CQRS commands to their registered handler via a map.
type CommandBus struct {
	handlers map[string]func(ctx context.Context, cmd CQRSCommand) error
}

func NewCommandBus() *CommandBus {
	return &CommandBus{handlers: make(map[string]func(context.Context, CQRSCommand) error)}
}

// RegisterHandler wires a typed handler into the bus. The generic adapter keeps
// each handler strongly typed while the bus stores them behind one signature.
func RegisterHandler[T CQRSCommand](bus *CommandBus, commandType string, handle func(ctx context.Context, cmd T) error) {
	bus.handlers[commandType] = func(ctx context.Context, cmd CQRSCommand) error {
		typed, ok := cmd.(T)
		if !ok {
			return fmt.Errorf("command %s: unexpected type %T", commandType, cmd)
		}
		return handle(ctx, typed)
	}
}

func (b *CommandBus) Dispatch(ctx context.Context, cmd CQRSCommand) error {
	handle, ok := b.handlers[cmd.CommandType()]
	if !ok {
		return fmt.Errorf("no handler for command: %s", cmd.CommandType())
	}
	return handle(ctx, cmd)
}

// Setup and usage
func ExampleBus(ctx context.Context, orderRepo OrderRepository, inventory InventoryService, payments PaymentService) error {
	bus := NewCommandBus()
	RegisterHandler(bus, "PlaceOrder", NewPlaceOrderHandler(orderRepo, inventory, payments).Handle)
	RegisterHandler(bus, "CancelOrder", NewCancelOrderHandler(orderRepo, payments).Handle)

	if err := bus.Dispatch(ctx, PlaceOrderCommand{
		BaseCommand:     NewBaseCommand(),
		CustomerID:      customerID,
		Items:           items,
		ShippingAddress: address,
	}); err != nil {
		return err
	}
	return bus.Dispatch(ctx, CancelOrderCommand{
		BaseCommand: NewBaseCommand(),
		OrderID:     orderID,
		Reason:      "Customer requested",
	})
}
```

## Text Editor Example (Undo/Redo)

```go
package command

import "fmt"

// TextEditor is the receiver text commands mutate.
type TextEditor interface {
	InsertAt(pos int, text string)
	DeleteRange(start, end int)
	Range(start, end int) string
}

// TextCommand is a synchronous, reversible editing operation. In-memory edits
// have no I/O, so they need neither ctx nor an error return.
type TextCommand interface {
	Execute()
	Undo()
	Name() string
}

// InsertTextCommand inserts text at a position.
type InsertTextCommand struct {
	editor   TextEditor
	text     string
	position int
}

func NewInsertTextCommand(editor TextEditor, text string, position int) *InsertTextCommand {
	return &InsertTextCommand{editor: editor, text: text, position: position}
}

func (c *InsertTextCommand) Execute() {
	c.editor.InsertAt(c.position, c.text)
}

func (c *InsertTextCommand) Undo() {
	c.editor.DeleteRange(c.position, c.position+len(c.text))
}

func (c *InsertTextCommand) Name() string {
	return fmt.Sprintf("Insert %q", truncate(c.text, 20))
}

// DeleteTextCommand deletes a range, remembering it for undo.
type DeleteTextCommand struct {
	editor      TextEditor
	start, end  int
	deletedText string
}

func NewDeleteTextCommand(editor TextEditor, start, end int) *DeleteTextCommand {
	return &DeleteTextCommand{editor: editor, start: start, end: end}
}

func (c *DeleteTextCommand) Execute() {
	c.deletedText = c.editor.Range(c.start, c.end)
	c.editor.DeleteRange(c.start, c.end)
}

func (c *DeleteTextCommand) Undo() {
	c.editor.InsertAt(c.start, c.deletedText)
}

func (c *DeleteTextCommand) Name() string {
	return fmt.Sprintf("Delete %q", truncate(c.deletedText, 20))
}

// ReplaceTextCommand replaces a range with new text.
type ReplaceTextCommand struct {
	editor       TextEditor
	start, end   int
	newText      string
	originalText string
}

func NewReplaceTextCommand(editor TextEditor, start, end int, newText string) *ReplaceTextCommand {
	return &ReplaceTextCommand{editor: editor, start: start, end: end, newText: newText}
}

func (c *ReplaceTextCommand) Execute() {
	c.originalText = c.editor.Range(c.start, c.end)
	c.editor.DeleteRange(c.start, c.end)
	c.editor.InsertAt(c.start, c.newText)
}

func (c *ReplaceTextCommand) Undo() {
	c.editor.DeleteRange(c.start, c.start+len(c.newText))
	c.editor.InsertAt(c.start, c.originalText)
}

func (c *ReplaceTextCommand) Name() string {
	return fmt.Sprintf("Replace %q with %q", truncate(c.originalText, 10), truncate(c.newText, 10))
}

// truncate shortens s to at most n bytes for display.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Decoupling | Sender and receiver are decoupled |
| Undo/Redo | Natural support for reversible operations |
| Queuing | Commands can be queued for later execution |
| Logging | Easy to log all commands |
| Transactions | Combine commands into macro operations |

## When to Use

- Need undo/redo functionality
- Queue operations for later
- Log operations for audit
- Parameterize objects with operations
- Implement transactional behavior
