---
name: cqrs-event-sourcing
description: Command Query Responsibility Segregation and Event Sourcing patterns
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# CQRS & Event Sourcing

## Overview

CQRS separates read and write operations into different models.
Event Sourcing stores state as a sequence of events rather than current state.

## CQRS Pattern

```
Traditional CRUD:
┌──────────────────────────────────────┐
│              Application             │
│    ┌──────────────────────────┐     │
│    │      Single Model        │     │
│    │   (Read + Write)         │     │
│    └────────────┬─────────────┘     │
│                 │                    │
│    ┌────────────▼─────────────┐     │
│    │       Database           │     │
│    └──────────────────────────┘     │
└──────────────────────────────────────┘

CQRS:
┌──────────────────────────────────────────────────┐
│                   Application                     │
│  ┌─────────────────┐    ┌─────────────────────┐  │
│  │  Command Side   │    │    Query Side       │  │
│  │  (Write Model)  │    │   (Read Model)      │  │
│  └────────┬────────┘    └──────────┬──────────┘  │
│           │                        │             │
│  ┌────────▼────────┐    ┌──────────▼──────────┐  │
│  │  Write Database │───►│   Read Database     │  │
│  │  (Normalized)   │sync│  (Denormalized)     │  │
│  └─────────────────┘    └─────────────────────┘  │
└──────────────────────────────────────────────────┘
```

## Directory Structure

```
internal/
└── order/                          # one bounded-context package
    ├── command.go                  # write side: command structs
    ├── command_handlers.go         # command handlers
    ├── query.go                    # read side: query structs
    ├── query_handlers.go           # query handlers
    ├── read_model.go               # denormalized read model
    ├── order.go                    # event-sourced aggregate
    ├── events.go                   # domain events
    ├── repository.go               # repository port
    ├── postgres/
    │   ├── event_store.go          # write-model storage
    │   ├── snapshot_store.go        # snapshots
    │   └── read_repository.go      # read-model storage
    └── projection/
        └── order_projection.go     # rebuilds the read model from events
```

## CQRS Implementation

### Commands

```go
// file: internal/order/command.go
package order

// CreateOrderCommand is an intent to change state (write side).
type CreateOrderCommand struct {
	CustomerID string
	Items      []CommandItem
}

type CommandItem struct {
	ProductID string
	Quantity  int
}

// file: internal/order/command_handlers.go
package order

import (
	"context"
	"fmt"
)

// EventPublisher is the small port the handler uses to sync the read side.
type EventPublisher interface {
	PublishAll(ctx context.Context, events []DomainEvent) error
}

type CreateOrderHandler struct {
	orders    OrderRepository
	publisher EventPublisher
}

func NewCreateOrderHandler(orders OrderRepository, publisher EventPublisher) *CreateOrderHandler {
	return &CreateOrderHandler{orders: orders, publisher: publisher}
}

func (h *CreateOrderHandler) Handle(ctx context.Context, cmd CreateOrderCommand) (string, error) {
	// Create the aggregate.
	order, err := NewOrder(h.orders.NextID(), cmd.CustomerID, cmd.Items)
	if err != nil {
		return "", fmt.Errorf("create order: %w", err)
	}

	// Save to the write model.
	if err := h.orders.Save(ctx, order); err != nil {
		return "", fmt.Errorf("save order: %w", err)
	}

	// Publish events so the read model can sync.
	if err := h.publisher.PublishAll(ctx, order.PullDomainEvents()); err != nil {
		return "", fmt.Errorf("publish events: %w", err)
	}
	return order.ID(), nil
}
```

### Queries

```go
// file: internal/order/query.go
package order

// GetOrderQuery asks for a single order (read side).
type GetOrderQuery struct {
	OrderID string
}

// file: internal/order/query_handlers.go
package order

import "context"

// ReadRepository is the read-side port over the denormalized store.
type ReadRepository interface {
	FindByID(ctx context.Context, orderID string) (*ReadModel, error)
}

type GetOrderHandler struct {
	reads ReadRepository
}

func NewGetOrderHandler(reads ReadRepository) *GetOrderHandler {
	return &GetOrderHandler{reads: reads}
}

func (h *GetOrderHandler) Handle(ctx context.Context, q GetOrderQuery) (*ReadModel, error) {
	// Query the read model, which is optimized for reads.
	return h.reads.FindByID(ctx, q.OrderID)
}

// file: internal/order/read_model.go
package order

import "time"

// ReadModel is denormalized and precomputed for fast reads.
type ReadModel struct {
	ID            string
	CustomerID    string
	CustomerName  string // denormalized
	CustomerEmail string // denormalized
	Items         []ReadItem
	Total         int64
	Status        string
	StatusLabel   string // computed
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type ReadItem struct {
	ProductID   string
	ProductName string // denormalized
	Quantity    int
	UnitPrice   int64
	Subtotal    int64
}

// CustomerView and ProductView carry the extra data a projection denormalizes.
type CustomerView struct {
	ID    string
	Name  string
	Email string
}

type ProductView struct {
	ID    string
	Name  string
	Price int64
}
```

### Projections (Read Model Sync)

```go
// file: internal/order/projection/order_projection.go
package projection

import (
	"context"
	"fmt"
	"time"

	"example.com/shop/internal/order"
)

// ReadStore is the small write port the projection persists through.
type ReadStore interface {
	Insert(ctx context.Context, m order.ReadModel) error
	UpdateStatus(ctx context.Context, orderID, status, label string, updatedAt time.Time) error
}

// Lookups fetches the extra data needed to denormalize.
type Lookups interface {
	Customer(ctx context.Context, customerID string) (order.CustomerView, error)
	Product(ctx context.Context, productID string) (order.ProductView, error)
}

// EventBus subscribes handlers to event types by name.
type EventBus interface {
	Subscribe(eventType string, handler func(ctx context.Context, e order.DomainEvent) error)
}

type OrderProjection struct {
	reads   ReadStore
	lookups Lookups
}

func NewOrderProjection(reads ReadStore, lookups Lookups) *OrderProjection {
	return &OrderProjection{reads: reads, lookups: lookups}
}

// Register wires each event type to its handler on the bus.
func (p *OrderProjection) Register(bus EventBus) {
	bus.Subscribe("OrderCreated", func(ctx context.Context, e order.DomainEvent) error {
		return p.onOrderCreated(ctx, e.(order.OrderCreated))
	})
	bus.Subscribe("OrderConfirmed", func(ctx context.Context, e order.DomainEvent) error {
		return p.onOrderConfirmed(ctx, e.(order.OrderConfirmed))
	})
	bus.Subscribe("OrderShipped", func(ctx context.Context, e order.DomainEvent) error {
		return p.onOrderShipped(ctx, e.(order.OrderShipped))
	})
}

func (p *OrderProjection) onOrderCreated(ctx context.Context, e order.OrderCreated) error {
	// Fetch additional data for denormalization.
	customer, err := p.lookups.Customer(ctx, e.CustomerID)
	if err != nil {
		return fmt.Errorf("lookup customer %s: %w", e.CustomerID, err)
	}

	items := make([]order.ReadItem, len(e.Items))
	for i, item := range e.Items {
		product, err := p.lookups.Product(ctx, item.ProductID)
		if err != nil {
			return fmt.Errorf("lookup product %s: %w", item.ProductID, err)
		}
		items[i] = order.ReadItem{
			ProductID:   item.ProductID,
			ProductName: product.Name,
			Quantity:    item.Quantity,
			UnitPrice:   product.Price,
			Subtotal:    int64(item.Quantity) * product.Price,
		}
	}

	// Build and insert the read model.
	return p.reads.Insert(ctx, order.ReadModel{
		ID:            e.OrderID,
		CustomerID:    e.CustomerID,
		CustomerName:  customer.Name,
		CustomerEmail: customer.Email,
		Items:         items,
		Total:         e.Total,
		Status:        "pending",
		StatusLabel:   "Pending",
		CreatedAt:     e.OccurredAt,
		UpdatedAt:     e.OccurredAt,
	})
}

func (p *OrderProjection) onOrderConfirmed(ctx context.Context, e order.OrderConfirmed) error {
	return p.reads.UpdateStatus(ctx, e.OrderID, "confirmed", "Confirmed", e.OccurredAt)
}

func (p *OrderProjection) onOrderShipped(ctx context.Context, e order.OrderShipped) error {
	label := fmt.Sprintf("Shipped - %s", e.TrackingNumber)
	return p.reads.UpdateStatus(ctx, e.OrderID, "shipped", label, e.OccurredAt)
}
```

## Event Sourcing

```
Traditional State Storage:
┌─────────────┐
│ Orders      │
├─────────────┤
│ id: 1       │
│ status: paid│  ← Only current state
│ total: 100  │
└─────────────┘

Event Sourcing:
┌────────────────────────────────────────────────────┐
│ Events                                             │
├────────────────────────────────────────────────────┤
│ 1. OrderCreated { id: 1, items: [...] }           │
│ 2. OrderItemAdded { orderId: 1, productId: 5 }    │
│ 3. OrderConfirmed { orderId: 1 }                  │
│ 4. PaymentReceived { orderId: 1, amount: 100 }    │
└────────────────────────────────────────────────────┘
         │
         ▼
    Replay events to get current state
```

### Event Store

```go
// file: internal/order/postgres/event_store.go
package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"example.com/shop/internal/order"
)

// StoredEvent is the persisted form of a domain event.
type StoredEvent struct {
	ID            string
	AggregateID   string
	AggregateType string
	EventType     string
	EventData     json.RawMessage
	Metadata      EventMetadata
	Version       int
	OccurredAt    time.Time
}

type EventMetadata struct {
	UserID        string `json:"userId,omitempty"`
	CorrelationID string `json:"correlationId,omitempty"`
	CausationID   string `json:"causationId,omitempty"`
}

// ErrConcurrency signals an optimistic-concurrency conflict.
var ErrConcurrency = errors.New("concurrency conflict")

type EventStore struct {
	pool *pgxpool.Pool
}

func NewEventStore(pool *pgxpool.Pool) *EventStore {
	return &EventStore{pool: pool}
}

func (s *EventStore) Append(ctx context.Context, aggregateID string, events []order.DomainEvent, expectedVersion int) (err error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback(ctx)
		}
	}()

	// Optimistic concurrency check.
	current, err := s.currentVersion(ctx, aggregateID)
	if err != nil {
		return err
	}
	if current != expectedVersion {
		return fmt.Errorf("%w: expected version %d, found %d", ErrConcurrency, expectedVersion, current)
	}

	// Append events.
	for i, event := range events {
		data, err := json.Marshal(event)
		if err != nil {
			return fmt.Errorf("marshal event: %w", err)
		}
		if _, err = tx.Exec(ctx,
			`INSERT INTO event_store
			 (id, aggregate_id, aggregate_type, event_type, event_data, version, occurred_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			uuid.NewString(), aggregateID, event.AggregateType(), event.EventType(),
			data, expectedVersion+i+1, time.Now()); err != nil {
			return fmt.Errorf("append event: %w", err)
		}
	}

	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

func (s *EventStore) Events(ctx context.Context, aggregateID string) ([]StoredEvent, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, aggregate_id, aggregate_type, event_type, event_data, version, occurred_at
		 FROM event_store WHERE aggregate_id = $1 ORDER BY version ASC`, aggregateID)
	if err != nil {
		return nil, fmt.Errorf("query events: %w", err)
	}
	defer rows.Close()

	var events []StoredEvent
	for rows.Next() {
		var e StoredEvent
		if err := rows.Scan(&e.ID, &e.AggregateID, &e.AggregateType, &e.EventType,
			&e.EventData, &e.Version, &e.OccurredAt); err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

func (s *EventStore) currentVersion(ctx context.Context, aggregateID string) (int, error) {
	var version int
	if err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(MAX(version), 0) FROM event_store WHERE aggregate_id = $1`,
		aggregateID).Scan(&version); err != nil {
		return 0, fmt.Errorf("current version: %w", err)
	}
	return version, nil
}
```

### Event-Sourced Aggregate

```go
// file: internal/order/order.go
package order

import (
	"errors"
	"fmt"
	"time"
)

type OrderStatus int

const (
	OrderStatusPending OrderStatus = iota
	OrderStatusConfirmed
	OrderStatusShipped
	OrderStatusCancelled
)

var (
	ErrInvalidOrderState = errors.New("invalid order state")
	ErrOrderNotFound     = errors.New("order not found")
)

// DomainEvent is the small interface every event satisfies.
type DomainEvent interface {
	EventType() string
	AggregateType() string
}

type OrderItem struct {
	ProductID string
	Quantity  int
	Price     int64
}

// Domain events.
type OrderCreated struct {
	OrderID    string
	CustomerID string
	Items      []OrderItem
	Total      int64
	OccurredAt time.Time
}

func (OrderCreated) EventType() string     { return "OrderCreated" }
func (OrderCreated) AggregateType() string { return "Order" }

type OrderConfirmed struct {
	OrderID    string
	OccurredAt time.Time
}

func (OrderConfirmed) EventType() string     { return "OrderConfirmed" }
func (OrderConfirmed) AggregateType() string { return "Order" }

type OrderItemAdded struct {
	OrderID    string
	ProductID  string
	Quantity   int
	Price      int64
	OccurredAt time.Time
}

func (OrderItemAdded) EventType() string     { return "OrderItemAdded" }
func (OrderItemAdded) AggregateType() string { return "Order" }

type OrderShipped struct {
	OrderID        string
	TrackingNumber string
	OccurredAt     time.Time
}

func (OrderShipped) EventType() string     { return "OrderShipped" }
func (OrderShipped) AggregateType() string { return "Order" }

// eventRecorder is embedded to give an aggregate its event-sourcing plumbing.
type eventRecorder struct {
	uncommitted []DomainEvent
	version     int
}

func (r *eventRecorder) Version() int                     { return r.version }
func (r *eventRecorder) UncommittedEvents() []DomainEvent { return r.uncommitted }
func (r *eventRecorder) ClearUncommitted()                { r.uncommitted = nil }

// Order is an event-sourced aggregate: its state is derived by applying events.
type Order struct {
	eventRecorder
	id         string
	customerID string
	items      []OrderItem
	status     OrderStatus
}

func (o *Order) ID() string          { return o.id }
func (o *Order) Status() OrderStatus { return o.status }

// NewOrder creates an order by applying the creation event.
func NewOrder(id, customerID string, items []OrderItem) (*Order, error) {
	if len(items) == 0 {
		return nil, errors.New("order must have at least one item")
	}
	var total int64
	for _, item := range items {
		total += int64(item.Quantity) * item.Price
	}

	o := &Order{}
	o.apply(OrderCreated{OrderID: id, CustomerID: customerID, Items: items, Total: total, OccurredAt: time.Now()})
	return o, nil
}

func (o *Order) Confirm() error {
	if o.status != OrderStatusPending {
		return fmt.Errorf("%w: only pending orders can be confirmed", ErrInvalidOrderState)
	}
	o.apply(OrderConfirmed{OrderID: o.id, OccurredAt: time.Now()})
	return nil
}

func (o *Order) AddItem(productID string, quantity int, price int64) error {
	if o.status != OrderStatusPending {
		return fmt.Errorf("%w: cannot add items to a non-pending order", ErrInvalidOrderState)
	}
	o.apply(OrderItemAdded{OrderID: o.id, ProductID: productID, Quantity: quantity, Price: price, OccurredAt: time.Now()})
	return nil
}

// apply mutates state and records the event as uncommitted.
func (o *Order) apply(event DomainEvent) {
	o.mutate(event)
	o.uncommitted = append(o.uncommitted, event)
	o.version++
}

// mutate updates in-memory state from an event without recording it.
func (o *Order) mutate(event DomainEvent) {
	switch e := event.(type) {
	case OrderCreated:
		o.id = e.OrderID
		o.customerID = e.CustomerID
		o.items = append([]OrderItem(nil), e.Items...)
		o.status = OrderStatusPending
	case OrderConfirmed:
		o.status = OrderStatusConfirmed
	case OrderItemAdded:
		o.items = append(o.items, OrderItem{ProductID: e.ProductID, Quantity: e.Quantity, Price: e.Price})
	}
}

// LoadOrderFromHistory reconstitutes an order by replaying its events.
func LoadOrderFromHistory(events []DomainEvent) *Order {
	o := &Order{}
	for _, event := range events {
		o.mutate(event)
		o.version++
	}
	return o
}
```

### Event-Sourced Repository

```go
// file: internal/order/postgres/order_repository.go
package postgres

import (
	"context"
	"fmt"

	"example.com/shop/internal/order"
)

// EventPublisher publishes events to projections and other subscribers.
type EventPublisher interface {
	Publish(ctx context.Context, event order.DomainEvent) error
}

// EventDeserializer maps a stored event back to a domain event.
type EventDeserializer interface {
	Deserialize(stored StoredEvent) (order.DomainEvent, error)
}

type EventSourcedOrderRepository struct {
	store      *EventStore
	publisher  EventPublisher
	serializer EventDeserializer
}

func NewEventSourcedOrderRepository(store *EventStore, publisher EventPublisher, serializer EventDeserializer) *EventSourcedOrderRepository {
	return &EventSourcedOrderRepository{store: store, publisher: publisher, serializer: serializer}
}

func (r *EventSourcedOrderRepository) Save(ctx context.Context, o *order.Order) error {
	events := o.UncommittedEvents()
	if len(events) == 0 {
		return nil
	}

	// Expected version is the version before the new events were applied.
	expected := o.Version() - len(events)
	if err := r.store.Append(ctx, o.ID(), events, expected); err != nil {
		return fmt.Errorf("append events: %w", err)
	}

	// Publish events for projections.
	for _, event := range events {
		if err := r.publisher.Publish(ctx, event); err != nil {
			return fmt.Errorf("publish event: %w", err)
		}
	}

	o.ClearUncommitted()
	return nil
}

func (r *EventSourcedOrderRepository) FindByID(ctx context.Context, id string) (*order.Order, error) {
	stored, err := r.store.Events(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("load events: %w", err)
	}
	if len(stored) == 0 {
		return nil, order.ErrOrderNotFound
	}

	// Reconstitute the aggregate from its events.
	events := make([]order.DomainEvent, len(stored))
	for i, s := range stored {
		event, err := r.serializer.Deserialize(s)
		if err != nil {
			return nil, fmt.Errorf("deserialize event %s: %w", s.ID, err)
		}
		events[i] = event
	}
	return order.LoadOrderFromHistory(events), nil
}
```

## Snapshots (Performance Optimization)

```go
// file: internal/order/postgres/snapshot_store.go
package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"example.com/shop/internal/order"
)

const snapshotThreshold = 100

// For aggregates with many events, periodically save snapshots.
type Snapshot struct {
	AggregateID string
	State       json.RawMessage
	Version     int
	CreatedAt   time.Time
}

type SnapshotStore struct {
	pool *pgxpool.Pool
}

func NewSnapshotStore(pool *pgxpool.Pool) *SnapshotStore {
	return &SnapshotStore{pool: pool}
}

func (s *SnapshotStore) Save(ctx context.Context, aggregateID string, state json.RawMessage, version int) error {
	if _, err := s.pool.Exec(ctx,
		`INSERT INTO snapshots (aggregate_id, state, version, created_at)
		 VALUES ($1, $2, $3, NOW())
		 ON CONFLICT (aggregate_id) DO UPDATE SET state = $2, version = $3, created_at = NOW()`,
		aggregateID, state, version); err != nil {
		return fmt.Errorf("save snapshot: %w", err)
	}
	return nil
}

// Latest returns the most recent snapshot; the bool reports whether one exists,
// so callers never have to interpret a (nil, nil) result.
func (s *SnapshotStore) Latest(ctx context.Context, aggregateID string) (Snapshot, bool, error) {
	var snap Snapshot
	err := s.pool.QueryRow(ctx,
		`SELECT aggregate_id, state, version, created_at FROM snapshots WHERE aggregate_id = $1`,
		aggregateID).Scan(&snap.AggregateID, &snap.State, &snap.Version, &snap.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Snapshot{}, false, nil
	}
	if err != nil {
		return Snapshot{}, false, fmt.Errorf("latest snapshot: %w", err)
	}
	return snap, true, nil
}

// Snapshot-aware FindByID: reconstitute from the latest snapshot plus the events
// that followed it. It replaces the basic FindByID once the repository also holds
// a *SnapshotStore (field snapshots).
func (r *EventSourcedOrderRepository) FindByID(ctx context.Context, id string) (*order.Order, error) {
	// Try the latest snapshot first.
	snapshot, found, err := r.snapshots.Latest(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("load snapshot: %w", err)
	}

	// Get events after the snapshot (or all events when there is none).
	fromVersion := 0
	if found {
		fromVersion = snapshot.Version
	}
	stored, err := r.store.EventsAfterVersion(ctx, id, fromVersion)
	if err != nil {
		return nil, fmt.Errorf("load events: %w", err)
	}
	if !found && len(stored) == 0 {
		return nil, order.ErrOrderNotFound
	}

	// Reconstitute from snapshot + events.
	o := order.NewEmptyOrder()
	if found {
		if o, err = order.NewOrderFromSnapshot(snapshot.State); err != nil {
			return nil, fmt.Errorf("restore snapshot: %w", err)
		}
	}

	events := make([]order.DomainEvent, len(stored))
	for i, s := range stored {
		event, err := r.serializer.Deserialize(s)
		if err != nil {
			return nil, fmt.Errorf("deserialize event %s: %w", s.ID, err)
		}
		events[i] = event
	}
	o.ReplayEvents(events)

	// Take a fresh snapshot when replay grew long.
	if len(stored) > snapshotThreshold {
		state, err := o.Snapshot()
		if err != nil {
			return nil, fmt.Errorf("build snapshot: %w", err)
		}
		if err := r.snapshots.Save(ctx, id, state, o.Version()); err != nil {
			return nil, fmt.Errorf("save snapshot: %w", err)
		}
	}
	return o, nil
}
```

## When to Use

### CQRS Benefits
- Different read/write scaling
- Optimized read models
- Complex domain logic separation
- Eventual consistency acceptable

### Event Sourcing Benefits
- Complete audit trail
- Temporal queries (state at any point)
- Event replay for debugging
- Rebuild read models from events

### When NOT to Use
- Simple CRUD applications
- Strong consistency required everywhere
- Small, simple domains
- Team unfamiliar with patterns
