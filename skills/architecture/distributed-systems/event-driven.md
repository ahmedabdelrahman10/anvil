---
name: event-driven-architecture
description: Event-driven architecture patterns for loosely coupled systems
category: architecture/distributed-systems
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Event-Driven Architecture

## Overview

Event-driven architecture (EDA) is a software design pattern where the flow
of the program is determined by events. It promotes loose coupling, scalability,
and real-time responsiveness.

## Core Concepts

```
┌─────────────────────────────────────────────────────────────┐
│                  EVENT-DRIVEN ARCHITECTURE                   │
│                                                             │
│  ┌─────────┐    Event    ┌─────────┐    Event   ┌─────────┐│
│  │Producer │ ──────────► │ Broker  │ ─────────► │Consumer ││
│  └─────────┘             └─────────┘            └─────────┘│
│                                                             │
│  Producers emit events → Brokers route → Consumers react    │
└─────────────────────────────────────────────────────────────┘
```

## Event Types

```go
// EventMeta is embedded in every event to carry the shared metadata.
// A method promoted onto the concrete type satisfies Event's Meta().
type EventMeta struct {
	EventID   string
	Timestamp time.Time
}

func newEventMeta() EventMeta {
	return EventMeta{EventID: uuid.NewString(), Timestamp: time.Now()}
}

func (m EventMeta) Meta() EventMeta { return m }

// Event is implemented by every concrete event type.
type Event interface {
	EventType() string
	Version() string
	Meta() EventMeta
}

// OrderPlacedEvent is a domain event — a business fact that happened.
type OrderPlacedEvent struct {
	EventMeta
	OrderID    string
	CustomerID string
	Items      []OrderItem
	Total      float64
}

func NewOrderPlacedEvent(orderID, customerID string, items []OrderItem, total float64) OrderPlacedEvent {
	return OrderPlacedEvent{EventMeta: newEventMeta(), OrderID: orderID, CustomerID: customerID, Items: items, Total: total}
}

func (OrderPlacedEvent) EventType() string { return "order.placed" }
func (OrderPlacedEvent) Version() string   { return "1.0" }

// OrderPlacedIntegrationEvent is an integration event for cross-service use.
type OrderPlacedIntegrationEvent struct {
	EventMeta
	OrderID     string
	CustomerID  string
	TotalAmount float64
	Currency    string
}

func (OrderPlacedIntegrationEvent) EventType() string { return "integration.order.placed" }
func (OrderPlacedIntegrationEvent) Version() string   { return "1.0" }

// ProcessPaymentCommand is a command event — a request to perform an action.
type ProcessPaymentCommand struct {
	EventMeta
	OrderID       string
	Amount        float64
	PaymentMethod string
}

func (ProcessPaymentCommand) EventType() string { return "command.process.payment" }
func (ProcessPaymentCommand) Version() string   { return "1.0" }

// PaymentStatus is the closed set of payment outcomes.
type PaymentStatus string

const (
	PaymentSuccess PaymentStatus = "success"
	PaymentFailure PaymentStatus = "failed"
)

// PaymentProcessedNotification is a notification event about a state change.
type PaymentProcessedNotification struct {
	EventMeta
	PaymentID string
	OrderID   string
	Status    PaymentStatus
}

func (PaymentProcessedNotification) EventType() string { return "notification.payment.processed" }
func (PaymentProcessedNotification) Version() string   { return "1.0" }
```

## Event Bus Implementation

```go
// EventHandler handles one event.
type EventHandler interface {
	Handle(ctx context.Context, event Event) error
}

// HandlerFunc adapts a plain function to EventHandler.
type HandlerFunc func(ctx context.Context, event Event) error

func (f HandlerFunc) Handle(ctx context.Context, event Event) error { return f(ctx, event) }

// EventBus publishes events and routes them to subscribed handlers.
// Subscribe returns a cancel func — the idiomatic Go form of unsubscribe.
type EventBus interface {
	Publish(ctx context.Context, event Event) error
	Subscribe(eventType string, handler EventHandler) (cancel func())
}

type subscription struct {
	handler EventHandler
}

// InMemoryEventBus is a single-process bus; handlers run on goroutines.
type InMemoryEventBus struct {
	mu       sync.RWMutex
	handlers map[string][]*subscription
	logger   *slog.Logger
}

func NewInMemoryEventBus(logger *slog.Logger) *InMemoryEventBus {
	return &InMemoryEventBus{handlers: make(map[string][]*subscription), logger: logger}
}

func (b *InMemoryEventBus) Publish(ctx context.Context, event Event) error {
	b.mu.RLock()
	subs := slices.Clone(b.handlers[event.EventType()])
	b.mu.RUnlock()

	var wg sync.WaitGroup
	for _, sub := range subs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := sub.handler.Handle(ctx, event); err != nil {
				// Isolate handler failures; one bad handler must not block the rest.
				b.logger.ErrorContext(ctx, "handler failed", "event_type", event.EventType(), "error", err)
			}
		}()
	}
	wg.Wait()
	return nil
}

func (b *InMemoryEventBus) Subscribe(eventType string, handler EventHandler) func() {
	sub := &subscription{handler: handler}

	b.mu.Lock()
	b.handlers[eventType] = append(b.handlers[eventType], sub)
	b.mu.Unlock()

	// Pointer identity makes cancellation safe without comparing handlers.
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		b.handlers[eventType] = slices.DeleteFunc(b.handlers[eventType], func(s *subscription) bool {
			return s == sub
		})
	}
}

// MessageBroker abstracts the transport (e.g. GCP Pub/Sub, Kafka).
type MessageBroker interface {
	Publish(ctx context.Context, topic string, msg BrokerMessage) error
	Subscribe(ctx context.Context, topic string, handler func(ctx context.Context, msg BrokerMessage) error) error
}

// BrokerMessage is the wire form: a routing key, a serialized value, and headers.
type BrokerMessage struct {
	Key     string
	Value   []byte
	Headers map[string]string
}

// EventSerializer marshals events to and from bytes.
type EventSerializer interface {
	Serialize(event Event) ([]byte, error)
	Deserialize(eventType string, data []byte) (Event, error)
}

// DistributedEventBus bridges the domain EventBus onto a message broker.
// It implements Publish; its consumer-side Subscribe is ctx-scoped and
// long-lived (a broker consumer loop), so it takes ctx and returns error.
type DistributedEventBus struct {
	broker     MessageBroker
	serializer EventSerializer
}

func NewDistributedEventBus(broker MessageBroker, serializer EventSerializer) *DistributedEventBus {
	return &DistributedEventBus{broker: broker, serializer: serializer}
}

func (b *DistributedEventBus) Publish(ctx context.Context, event Event) error {
	value, err := b.serializer.Serialize(event)
	if err != nil {
		return fmt.Errorf("serialize %s: %w", event.EventType(), err)
	}

	msg := BrokerMessage{
		Key:   event.Meta().EventID,
		Value: value,
		Headers: map[string]string{
			"event-type":    event.EventType(),
			"event-version": event.Version(),
			"timestamp":     event.Meta().Timestamp.Format(time.RFC3339),
		},
	}
	if err := b.broker.Publish(ctx, event.EventType(), msg); err != nil {
		return fmt.Errorf("broker publish %s: %w", event.EventType(), err)
	}
	return nil
}

func (b *DistributedEventBus) Subscribe(ctx context.Context, eventType string, handler EventHandler) error {
	return b.broker.Subscribe(ctx, eventType, func(ctx context.Context, msg BrokerMessage) error {
		event, err := b.serializer.Deserialize(eventType, msg.Value)
		if err != nil {
			return fmt.Errorf("deserialize %s: %w", eventType, err)
		}
		return handler.Handle(ctx, event)
	})
}
```

## Event Sourcing

```go
// IgnoreVersion disables the optimistic-concurrency check in Append.
const IgnoreVersion = -1

// ErrSnapshotNotFound is returned when a stream has no snapshot yet.
var ErrSnapshotNotFound = errors.New("snapshot not found")

// ErrOrderNotFound is returned when a stream has no events.
var ErrOrderNotFound = errors.New("order not found")

// EventStore appends and reads event streams, with optional snapshots.
type EventStore interface {
	Append(ctx context.Context, streamID string, events []Event, expectedVersion int) error
	GetEvents(ctx context.Context, streamID string, fromVersion int) ([]StoredEvent, error)
	GetSnapshot(ctx context.Context, streamID string) (Snapshot, error)
	SaveSnapshot(ctx context.Context, snapshot Snapshot) error
}

type StoredEvent struct {
	EventID   string
	StreamID  string
	Version   int
	EventType string
	Data      json.RawMessage
	Metadata  EventMetadata
	Timestamp time.Time
}

type EventMetadata struct {
	Version string `json:"version"`
}

type Snapshot struct {
	StreamID  string
	Version   int
	State     json.RawMessage
	Timestamp time.Time
}

// ConcurrencyError signals an optimistic-concurrency conflict on append.
type ConcurrencyError struct {
	Expected int
	Current  int
}

func (e *ConcurrencyError) Error() string {
	return fmt.Sprintf("concurrency conflict: expected version %d, but current is %d", e.Expected, e.Current)
}

// PostgresEventStore is a PostgreSQL-backed EventStore.
type PostgresEventStore struct {
	pool *pgxpool.Pool
}

func NewPostgresEventStore(pool *pgxpool.Pool) *PostgresEventStore {
	return &PostgresEventStore{pool: pool}
}

func (s *PostgresEventStore) Append(ctx context.Context, streamID string, events []Event, expectedVersion int) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) // no-op once Commit succeeds

	version, err := s.currentVersion(ctx, tx, streamID)
	if err != nil {
		return fmt.Errorf("read current version: %w", err)
	}

	// Optimistic concurrency check.
	if expectedVersion != IgnoreVersion && version != expectedVersion {
		return &ConcurrencyError{Expected: expectedVersion, Current: version}
	}

	for _, event := range events {
		version++
		data, err := json.Marshal(event)
		if err != nil {
			return fmt.Errorf("marshal event: %w", err)
		}
		meta, err := json.Marshal(EventMetadata{Version: event.Version()})
		if err != nil {
			return fmt.Errorf("marshal metadata: %w", err)
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO events (event_id, stream_id, version, event_type, data, metadata, timestamp)
			 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
			event.Meta().EventID, streamID, version, event.EventType(), data, meta, event.Meta().Timestamp)
		if err != nil {
			return fmt.Errorf("insert event: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

func (s *PostgresEventStore) GetEvents(ctx context.Context, streamID string, fromVersion int) ([]StoredEvent, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT event_id, stream_id, version, event_type, data, metadata, timestamp
		 FROM events WHERE stream_id = $1 AND version > $2 ORDER BY version ASC`,
		streamID, fromVersion)
	if err != nil {
		return nil, fmt.Errorf("query events: %w", err)
	}
	defer rows.Close()

	var events []StoredEvent
	for rows.Next() {
		var (
			e    StoredEvent
			meta []byte
		)
		if err := rows.Scan(&e.EventID, &e.StreamID, &e.Version, &e.EventType, &e.Data, &meta, &e.Timestamp); err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		if err := json.Unmarshal(meta, &e.Metadata); err != nil {
			return nil, fmt.Errorf("unmarshal metadata: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate events: %w", err)
	}
	return events, nil
}

func (s *PostgresEventStore) GetSnapshot(ctx context.Context, streamID string) (Snapshot, error) {
	row := s.pool.QueryRow(ctx,
		`SELECT stream_id, version, state, timestamp FROM snapshots
		 WHERE stream_id = $1 ORDER BY version DESC LIMIT 1`, streamID)

	var snap Snapshot
	if err := row.Scan(&snap.StreamID, &snap.Version, &snap.State, &snap.Timestamp); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Snapshot{}, ErrSnapshotNotFound
		}
		return Snapshot{}, fmt.Errorf("scan snapshot: %w", err)
	}
	return snap, nil
}

func (s *PostgresEventStore) SaveSnapshot(ctx context.Context, snapshot Snapshot) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO snapshots (stream_id, version, state, timestamp)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (stream_id, version) DO UPDATE SET state = $3, timestamp = $4`,
		snapshot.StreamID, snapshot.Version, snapshot.State, snapshot.Timestamp)
	if err != nil {
		return fmt.Errorf("upsert snapshot: %w", err)
	}
	return nil
}

func (s *PostgresEventStore) currentVersion(ctx context.Context, tx pgx.Tx, streamID string) (int, error) {
	var version *int // MAX(version) is NULL for an empty stream
	if err := tx.QueryRow(ctx, `SELECT MAX(version) FROM events WHERE stream_id = $1`, streamID).Scan(&version); err != nil {
		return 0, fmt.Errorf("query max version: %w", err)
	}
	if version == nil {
		return 0, nil
	}
	return *version, nil
}

// Go has no inheritance, so an aggregate composes a change tracker and owns
// its own state transition (when) rather than overriding an abstract method.

// aggregateChanges tracks uncommitted events and the current version.
type aggregateChanges struct {
	uncommitted []Event
	version     int
}

func (c *aggregateChanges) record(event Event) {
	c.uncommitted = append(c.uncommitted, event)
	c.version++
}

func (c *aggregateChanges) Version() int               { return c.version }
func (c *aggregateChanges) UncommittedEvents() []Event { return slices.Clone(c.uncommitted) }
func (c *aggregateChanges) ClearUncommitted()          { c.uncommitted = nil }

type OrderStatus string

const (
	OrderStatusDraft   OrderStatus = "draft"
	OrderStatusPlaced  OrderStatus = "placed"
	OrderStatusShipped OrderStatus = "shipped"
)

// ErrInvalidOperation marks a command issued in the wrong aggregate state.
var ErrInvalidOperation = errors.New("invalid operation for current state")

// OrderCreatedEvent and OrderShippedEvent are the domain events for the Order
// aggregate (OrderPlacedEvent is defined in the Event Types section above).
type OrderCreatedEvent struct {
	EventMeta
	OrderID    string
	CustomerID string
	Items      []OrderItem
	Total      float64
}

func NewOrderCreatedEvent(orderID, customerID string, items []OrderItem, total float64) OrderCreatedEvent {
	return OrderCreatedEvent{EventMeta: newEventMeta(), OrderID: orderID, CustomerID: customerID, Items: items, Total: total}
}

func (OrderCreatedEvent) EventType() string { return "order.created" }
func (OrderCreatedEvent) Version() string   { return "1.0" }

type OrderShippedEvent struct {
	EventMeta
	OrderID        string
	TrackingNumber string
}

func NewOrderShippedEvent(orderID, trackingNumber string) OrderShippedEvent {
	return OrderShippedEvent{EventMeta: newEventMeta(), OrderID: orderID, TrackingNumber: trackingNumber}
}

func (OrderShippedEvent) EventType() string { return "order.shipped" }
func (OrderShippedEvent) Version() string   { return "1.0" }

// Order is an event-sourced aggregate.
type Order struct {
	aggregateChanges
	id         string
	customerID string
	items      []OrderItem
	status     OrderStatus
	total      float64
}

func (o *Order) ID() string { return o.id }

// NewOrder returns an empty aggregate for loading from history or a snapshot.
func NewOrder() *Order { return &Order{} }

// CreateOrder starts a brand-new order aggregate.
func CreateOrder(customerID string, items []OrderItem) *Order {
	var total float64
	for _, item := range items {
		total += item.Price * float64(item.Quantity)
	}
	o := &Order{}
	o.apply(NewOrderCreatedEvent(uuid.NewString(), customerID, items, total))
	return o
}

func (o *Order) Place() error {
	if o.status != OrderStatusDraft {
		return fmt.Errorf("place order %s: %w", o.id, ErrInvalidOperation)
	}
	o.apply(NewOrderPlacedEvent(o.id, o.customerID, o.items, o.total))
	return nil
}

func (o *Order) Ship(trackingNumber string) error {
	if o.status != OrderStatusPlaced {
		return fmt.Errorf("ship order %s: %w", o.id, ErrInvalidOperation)
	}
	o.apply(NewOrderShippedEvent(o.id, trackingNumber))
	return nil
}

// apply mutates state via when, then records the event as uncommitted.
func (o *Order) apply(event Event) {
	o.when(event)
	o.record(event)
}

// when is the pure state transition for each event (no side effects).
func (o *Order) when(event Event) {
	switch e := event.(type) {
	case OrderCreatedEvent:
		o.id = e.OrderID
		o.customerID = e.CustomerID
		o.items = e.Items
		o.total = e.Total
		o.status = OrderStatusDraft
	case OrderPlacedEvent:
		o.status = OrderStatusPlaced
	case OrderShippedEvent:
		o.status = OrderStatusShipped
	}
}

// LoadFromHistory replays stored events to rebuild the current state.
func (o *Order) LoadFromHistory(events []StoredEvent) error {
	for _, stored := range events {
		event, err := decodeOrderEvent(stored)
		if err != nil {
			return fmt.Errorf("decode event %s: %w", stored.EventID, err)
		}
		o.when(event)
		o.version = stored.Version
	}
	return nil
}

type orderSnapshot struct {
	ID         string      `json:"id"`
	CustomerID string      `json:"customerId"`
	Items      []OrderItem `json:"items"`
	Status     OrderStatus `json:"status"`
	Total      float64     `json:"total"`
}

// Snapshot serializes current state for a point-in-time snapshot.
func (o *Order) Snapshot() (json.RawMessage, error) {
	out, err := json.Marshal(orderSnapshot{
		ID:         o.id,
		CustomerID: o.customerID,
		Items:      o.items,
		Status:     o.status,
		Total:      o.total,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal order snapshot: %w", err)
	}
	return out, nil
}

// LoadFromSnapshot restores state from a snapshot, then replays newer events.
func (o *Order) LoadFromSnapshot(snapshot Snapshot, events []StoredEvent) error {
	var state orderSnapshot
	if err := json.Unmarshal(snapshot.State, &state); err != nil {
		return fmt.Errorf("unmarshal snapshot: %w", err)
	}
	o.id = state.ID
	o.customerID = state.CustomerID
	o.items = state.Items
	o.status = state.Status
	o.total = state.Total
	o.version = snapshot.Version
	return o.LoadFromHistory(events)
}

// decodeOrderEvent turns a stored record back into its concrete event type.
func decodeOrderEvent(stored StoredEvent) (Event, error) {
	switch stored.EventType {
	case "order.created":
		var e OrderCreatedEvent
		if err := json.Unmarshal(stored.Data, &e); err != nil {
			return nil, err
		}
		return e, nil
	case "order.placed":
		var e OrderPlacedEvent
		if err := json.Unmarshal(stored.Data, &e); err != nil {
			return nil, err
		}
		return e, nil
	case "order.shipped":
		var e OrderShippedEvent
		if err := json.Unmarshal(stored.Data, &e); err != nil {
			return nil, err
		}
		return e, nil
	default:
		return nil, fmt.Errorf("unknown event type %q", stored.EventType)
	}
}

// EventSourcedOrderRepository loads and saves orders via the event store.
type EventSourcedOrderRepository struct {
	eventStore        EventStore
	snapshotFrequency int
}

func NewEventSourcedOrderRepository(eventStore EventStore, snapshotFrequency int) *EventSourcedOrderRepository {
	if snapshotFrequency <= 0 {
		snapshotFrequency = 100
	}
	return &EventSourcedOrderRepository{eventStore: eventStore, snapshotFrequency: snapshotFrequency}
}

func (r *EventSourcedOrderRepository) Save(ctx context.Context, order *Order) error {
	events := order.UncommittedEvents()
	stream := orderStreamID(order.ID())
	if err := r.eventStore.Append(ctx, stream, events, order.Version()-len(events)); err != nil {
		return fmt.Errorf("append events: %w", err)
	}
	order.ClearUncommitted()

	// Take a snapshot periodically.
	if order.Version()%r.snapshotFrequency != 0 {
		return nil
	}
	state, err := order.Snapshot()
	if err != nil {
		return fmt.Errorf("build snapshot: %w", err)
	}
	err = r.eventStore.SaveSnapshot(ctx, Snapshot{
		StreamID:  stream,
		Version:   order.Version(),
		State:     state,
		Timestamp: time.Now(),
	})
	if err != nil {
		return fmt.Errorf("save snapshot: %w", err)
	}
	return nil
}

func (r *EventSourcedOrderRepository) GetByID(ctx context.Context, orderID string) (*Order, error) {
	stream := orderStreamID(orderID)
	order := NewOrder()

	snapshot, err := r.eventStore.GetSnapshot(ctx, stream)
	switch {
	case err == nil:
		events, err := r.eventStore.GetEvents(ctx, stream, snapshot.Version)
		if err != nil {
			return nil, fmt.Errorf("get events after snapshot: %w", err)
		}
		if err := order.LoadFromSnapshot(snapshot, events); err != nil {
			return nil, fmt.Errorf("load from snapshot: %w", err)
		}
	case errors.Is(err, ErrSnapshotNotFound):
		events, err := r.eventStore.GetEvents(ctx, stream, 0)
		if err != nil {
			return nil, fmt.Errorf("get events: %w", err)
		}
		if len(events) == 0 {
			return nil, ErrOrderNotFound
		}
		if err := order.LoadFromHistory(events); err != nil {
			return nil, fmt.Errorf("load from history: %w", err)
		}
	default:
		return nil, fmt.Errorf("get snapshot: %w", err)
	}
	return order, nil
}

func orderStreamID(orderID string) string { return "order-" + orderID }
```

## Event Handlers and Projections

```go
// TypedEventHandler is an EventHandler that also declares the event type it wants,
// so a registry can route events to it.
type TypedEventHandler interface {
	EventHandler
	EventType() string
}

// Notification is a message the notification service sends.
type Notification struct {
	To       string
	Template string
	Data     map[string]any
}

// OrderReadModelProjection maintains the order read model.
type OrderReadModelProjection struct {
	readDB *pgxpool.Pool
}

func NewOrderReadModelProjection(readDB *pgxpool.Pool) *OrderReadModelProjection {
	return &OrderReadModelProjection{readDB: readDB}
}

func (OrderReadModelProjection) EventType() string { return "order.placed" }

func (p *OrderReadModelProjection) Handle(ctx context.Context, event Event) error {
	e, ok := event.(OrderPlacedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	_, err := p.readDB.Exec(ctx,
		`INSERT INTO order_read_model (id, customer_id, status, total, item_count, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6)
		 ON CONFLICT (id) DO UPDATE SET status = $3`,
		e.OrderID, e.CustomerID, "placed", e.Total, len(e.Items), e.Meta().Timestamp)
	if err != nil {
		return fmt.Errorf("upsert order_read_model: %w", err)
	}
	return nil
}

// OrderNotificationHandler emails the customer when an order is placed.
type OrderNotificationHandler struct {
	notifications NotificationService
	customers     CustomerService
}

func NewOrderNotificationHandler(notifications NotificationService, customers CustomerService) *OrderNotificationHandler {
	return &OrderNotificationHandler{notifications: notifications, customers: customers}
}

func (OrderNotificationHandler) EventType() string { return "order.placed" }

func (h *OrderNotificationHandler) Handle(ctx context.Context, event Event) error {
	e, ok := event.(OrderPlacedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	customer, err := h.customers.GetByID(ctx, e.CustomerID)
	if err != nil {
		return fmt.Errorf("get customer %s: %w", e.CustomerID, err)
	}
	err = h.notifications.Send(ctx, Notification{
		To:       customer.Email,
		Template: "order-confirmation",
		Data: map[string]any{
			"orderId": e.OrderID,
			"total":   e.Total,
			"items":   e.Items,
		},
	})
	if err != nil {
		return fmt.Errorf("send order confirmation: %w", err)
	}
	return nil
}

// OrderAnalyticsHandler tracks order placement in the analytics pipeline.
type OrderAnalyticsHandler struct {
	analytics AnalyticsService
}

func NewOrderAnalyticsHandler(analytics AnalyticsService) *OrderAnalyticsHandler {
	return &OrderAnalyticsHandler{analytics: analytics}
}

func (OrderAnalyticsHandler) EventType() string { return "order.placed" }

func (h *OrderAnalyticsHandler) Handle(ctx context.Context, event Event) error {
	e, ok := event.(OrderPlacedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	err := h.analytics.Track(ctx, "order_placed", map[string]any{
		"orderId":    e.OrderID,
		"customerId": e.CustomerID,
		"total":      e.Total,
		"itemCount":  len(e.Items),
		"timestamp":  e.Meta().Timestamp,
	})
	if err != nil {
		return fmt.Errorf("track order_placed: %w", err)
	}
	return nil
}

// EventHandlerRegistry dispatches an event to every handler registered for its type.
type EventHandlerRegistry struct {
	mu       sync.RWMutex
	handlers map[string][]TypedEventHandler
	logger   *slog.Logger
}

func NewEventHandlerRegistry(logger *slog.Logger) *EventHandlerRegistry {
	return &EventHandlerRegistry{handlers: make(map[string][]TypedEventHandler), logger: logger}
}

func (r *EventHandlerRegistry) Register(handler TypedEventHandler) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.handlers[handler.EventType()] = append(r.handlers[handler.EventType()], handler)
}

func (r *EventHandlerRegistry) Dispatch(ctx context.Context, event Event) {
	r.mu.RLock()
	handlers := slices.Clone(r.handlers[event.EventType()])
	r.mu.RUnlock()

	var wg sync.WaitGroup
	for _, handler := range handlers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := handler.Handle(ctx, event); err != nil {
				// Log and continue; consider a dead-letter queue for failed events.
				r.logger.ErrorContext(ctx, "handler failed", "event_type", event.EventType(), "error", err)
			}
		}()
	}
	wg.Wait()
}
```

## Event Schema Evolution

```go
// EventUpcaster upgrades a serialized event from one version to the next.
type EventUpcaster interface {
	FromVersion() string
	ToVersion() string
	Upcast(data json.RawMessage) (json.RawMessage, error)
}

// EventUpcasterChain upgrades an event step by step to a target version.
type EventUpcasterChain struct {
	// byFromVersion maps a source version to the upcaster that leaves it.
	byFromVersion map[string]EventUpcaster
}

func NewEventUpcasterChain() *EventUpcasterChain {
	return &EventUpcasterChain{byFromVersion: make(map[string]EventUpcaster)}
}

func (c *EventUpcasterChain) Register(upcaster EventUpcaster) {
	c.byFromVersion[upcaster.FromVersion()] = upcaster
}

func (c *EventUpcasterChain) Upcast(data json.RawMessage, fromVersion, targetVersion string) (json.RawMessage, error) {
	current := data
	version := fromVersion

	for version != targetVersion {
		upcaster, ok := c.byFromVersion[version]
		if !ok {
			return nil, fmt.Errorf("no upcaster for version %s", version)
		}
		next, err := upcaster.Upcast(current)
		if err != nil {
			return nil, fmt.Errorf("upcast %s->%s: %w", upcaster.FromVersion(), upcaster.ToVersion(), err)
		}
		current = next
		version = upcaster.ToVersion()
	}
	return current, nil
}

// Order event evolution: V1 stores items as product-id strings; V2 stores them
// as OrderItem objects.
type OrderPlacedEventV1ToV2Upcaster struct{}

func (OrderPlacedEventV1ToV2Upcaster) FromVersion() string { return "1.0" }
func (OrderPlacedEventV1ToV2Upcaster) ToVersion() string   { return "2.0" }

func (OrderPlacedEventV1ToV2Upcaster) Upcast(data json.RawMessage) (json.RawMessage, error) {
	var v1 struct {
		OrderID    string   `json:"orderId"`
		CustomerID string   `json:"customerId"`
		Items      []string `json:"items"`
		Total      float64  `json:"total"`
	}
	if err := json.Unmarshal(data, &v1); err != nil {
		return nil, fmt.Errorf("unmarshal v1: %w", err)
	}

	items := make([]OrderItem, len(v1.Items))
	for i, productID := range v1.Items {
		items[i] = OrderItem{ProductID: productID, Quantity: 1, Price: 0} // price unknown, would need a lookup
	}

	out, err := json.Marshal(struct {
		OrderID    string      `json:"orderId"`
		CustomerID string      `json:"customerId"`
		Items      []OrderItem `json:"items"`
		Total      float64     `json:"total"`
		Version    string      `json:"version"`
	}{
		OrderID:    v1.OrderID,
		CustomerID: v1.CustomerID,
		Items:      items,
		Total:      v1.Total,
		Version:    "2.0",
	})
	if err != nil {
		return nil, fmt.Errorf("marshal v2: %w", err)
	}
	return out, nil
}

// ValidationResult reports whether an event matches its schema.
type ValidationResult struct {
	Valid  bool
	Errors []string
}

// SchemaValidator validates a serialized payload against a JSON schema.
type SchemaValidator interface {
	Validate(data json.RawMessage) ValidationResult
}

// EventSchemaRegistry validates events against a schema per type+version.
type EventSchemaRegistry struct {
	schemas map[string]SchemaValidator
}

func NewEventSchemaRegistry() *EventSchemaRegistry {
	return &EventSchemaRegistry{schemas: make(map[string]SchemaValidator)}
}

func (r *EventSchemaRegistry) Register(eventType, version string, schema SchemaValidator) {
	r.schemas[eventType+":"+version] = schema
}

func (r *EventSchemaRegistry) Validate(event Event) ValidationResult {
	schema, ok := r.schemas[event.EventType()+":"+event.Version()]
	if !ok {
		return ValidationResult{Valid: false, Errors: []string{"schema not found"}}
	}
	data, err := json.Marshal(event)
	if err != nil {
		return ValidationResult{Valid: false, Errors: []string{err.Error()}}
	}
	return schema.Validate(data)
}
```

## Dead Letter Queue

```go
// ErrNetwork marks a transient network failure worth retrying.
var ErrNetwork = errors.New("network error")

// DeadLetterEntry records an event a handler failed to process.
type DeadLetterEntry struct {
	ID           string
	Event        Event
	Err          string
	Attempts     int
	FirstFailure time.Time
	LastFailure  time.Time
	Handler      string
}

// DeadLetterStorage persists dead-letter entries.
type DeadLetterStorage interface {
	FindByEventID(ctx context.Context, eventID string) (*DeadLetterEntry, error)
	FindByID(ctx context.Context, id string) (*DeadLetterEntry, error)
	FindAll(ctx context.Context, limit, offset int) ([]DeadLetterEntry, error)
	Create(ctx context.Context, entry DeadLetterEntry) error
	Update(ctx context.Context, entry DeadLetterEntry) error
	Delete(ctx context.Context, id string) error
}

// DeadLetterQueue tracks failed events and can replay them onto the bus.
type DeadLetterQueue struct {
	storage DeadLetterStorage
	bus     EventBus
}

func NewDeadLetterQueue(storage DeadLetterStorage, bus EventBus) *DeadLetterQueue {
	return &DeadLetterQueue{storage: storage, bus: bus}
}

func (q *DeadLetterQueue) Add(ctx context.Context, event Event, cause error, handler string) error {
	existing, err := q.storage.FindByEventID(ctx, event.Meta().EventID)
	if err != nil {
		return fmt.Errorf("find dead letter: %w", err)
	}

	if existing != nil {
		existing.Attempts++
		existing.LastFailure = time.Now()
		existing.Err = cause.Error()
		if err := q.storage.Update(ctx, *existing); err != nil {
			return fmt.Errorf("update dead letter: %w", err)
		}
		return nil
	}

	now := time.Now()
	err = q.storage.Create(ctx, DeadLetterEntry{
		ID:           uuid.NewString(),
		Event:        event,
		Err:          cause.Error(),
		Attempts:     1,
		FirstFailure: now,
		LastFailure:  now,
		Handler:      handler,
	})
	if err != nil {
		return fmt.Errorf("create dead letter: %w", err)
	}
	return nil
}

func (q *DeadLetterQueue) Retry(ctx context.Context, entryID string) error {
	entry, err := q.storage.FindByID(ctx, entryID)
	if err != nil {
		return fmt.Errorf("find dead letter %s: %w", entryID, err)
	}
	if entry == nil {
		return fmt.Errorf("dead letter %s not found", entryID)
	}

	if err := q.bus.Publish(ctx, entry.Event); err != nil {
		entry.Attempts++
		entry.LastFailure = time.Now()
		entry.Err = err.Error()
		if updateErr := q.storage.Update(ctx, *entry); updateErr != nil {
			return fmt.Errorf("update after failed retry: %w", errors.Join(err, updateErr))
		}
		return fmt.Errorf("republish dead letter %s: %w", entryID, err)
	}

	if err := q.storage.Delete(ctx, entryID); err != nil {
		return fmt.Errorf("delete dead letter %s: %w", entryID, err)
	}
	return nil
}

func (q *DeadLetterQueue) Entries(ctx context.Context, limit, offset int) ([]DeadLetterEntry, error) {
	entries, err := q.storage.FindAll(ctx, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list dead letters: %w", err)
	}
	return entries, nil
}

// ResilientEventHandler wraps a handler: transient errors bubble up for broker
// retry, terminal errors go to the dead-letter queue.
type ResilientEventHandler struct {
	handler     EventHandler
	dlq         *DeadLetterQueue
	handlerName string
}

func NewResilientEventHandler(handler EventHandler, dlq *DeadLetterQueue, handlerName string) *ResilientEventHandler {
	return &ResilientEventHandler{handler: handler, dlq: dlq, handlerName: handlerName}
}

func (h *ResilientEventHandler) Handle(ctx context.Context, event Event) error {
	err := h.handler.Handle(ctx, event)
	if err == nil {
		return nil
	}

	if isTransient(err) {
		return fmt.Errorf("transient handler error (let the broker retry): %w", err)
	}
	if dlqErr := h.dlq.Add(ctx, event, err, h.handlerName); dlqErr != nil {
		return fmt.Errorf("dead-letter %s: %w", event.EventType(), errors.Join(err, dlqErr))
	}
	return nil
}

// isTransient reports whether an error is worth retrying.
func isTransient(err error) bool {
	// Transient errors (network, timeout) should be retried.
	return errors.Is(err, ErrNetwork) || errors.Is(err, context.DeadlineExceeded)
}
```

## Event Choreography vs Orchestration

```go
// Choreography: services react to events independently, with no coordinator.
// Orchestration: a central coordinator reacts to events and issues commands.

// WorkflowStep is one step in a workflow instance.
type WorkflowStep struct {
	Name   string
	Status string
}

// Workflow tracks an order's progress across services.
type Workflow struct {
	OrderID         string
	Status          string
	Steps           []WorkflowStep
	Items           []OrderItem
	ShippingAddress string
}

func (w *Workflow) UpdateStep(name, status string) {
	for i := range w.Steps {
		if w.Steps[i].Name == name {
			w.Steps[i].Status = status
			return
		}
	}
}

// WorkflowStore persists workflow instances.
type WorkflowStore interface {
	Create(ctx context.Context, workflow Workflow) (*Workflow, error)
	FindByOrderID(ctx context.Context, orderID string) (*Workflow, error)
	Update(ctx context.Context, workflow Workflow) error
}

// Command events the orchestrator issues. The incoming domain events it reacts
// to (OrderCreatedEvent, PaymentCompletedEvent, PaymentFailedEvent,
// InventoryReservedEvent, InventoryFailedEvent) are defined in earlier sections.
type ReserveInventoryCommand struct {
	EventMeta
	OrderID string
	Items   []OrderItem
}

func (ReserveInventoryCommand) EventType() string { return "command.reserve.inventory" }
func (ReserveInventoryCommand) Version() string   { return "1.0" }

type CreateShipmentCommand struct {
	EventMeta
	OrderID         string
	ShippingAddress string
}

func (CreateShipmentCommand) EventType() string { return "command.create.shipment" }
func (CreateShipmentCommand) Version() string   { return "1.0" }

type CancelOrderCommand struct {
	EventMeta
	OrderID string
	Reason  string
}

func (CancelOrderCommand) EventType() string { return "command.cancel.order" }
func (CancelOrderCommand) Version() string   { return "1.0" }

type RefundPaymentCommand struct {
	EventMeta
	OrderID string
}

func (RefundPaymentCommand) EventType() string { return "command.refund.payment" }
func (RefundPaymentCommand) Version() string   { return "1.0" }

// OrderWorkflowOrchestrator is the central coordinator (orchestration): it
// subscribes to events and drives the next command.
type OrderWorkflowOrchestrator struct {
	bus       EventBus
	workflows WorkflowStore
}

func NewOrderWorkflowOrchestrator(bus EventBus, workflows WorkflowStore) *OrderWorkflowOrchestrator {
	o := &OrderWorkflowOrchestrator{bus: bus, workflows: workflows}
	bus.Subscribe("order.created", HandlerFunc(o.handleOrderCreated))
	bus.Subscribe("payment.completed", HandlerFunc(o.handlePaymentCompleted))
	bus.Subscribe("payment.failed", HandlerFunc(o.handlePaymentFailed))
	bus.Subscribe("inventory.reserved", HandlerFunc(o.handleInventoryReserved))
	bus.Subscribe("inventory.failed", HandlerFunc(o.handleInventoryFailed))
	return o
}

func (o *OrderWorkflowOrchestrator) handleOrderCreated(ctx context.Context, event Event) error {
	e, ok := event.(OrderCreatedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}

	// Create the workflow instance.
	_, err := o.workflows.Create(ctx, Workflow{
		OrderID: e.OrderID,
		Status:  "pending_payment",
		Steps: []WorkflowStep{
			{Name: "payment", Status: "pending"},
			{Name: "inventory", Status: "pending"},
			{Name: "shipping", Status: "pending"},
		},
	})
	if err != nil {
		return fmt.Errorf("create workflow: %w", err)
	}

	// Command the payment service.
	return o.bus.Publish(ctx, ProcessPaymentCommand{
		EventMeta:     newEventMeta(),
		OrderID:       e.OrderID,
		Amount:        e.Total,
		PaymentMethod: "credit_card",
	})
}

func (o *OrderWorkflowOrchestrator) handlePaymentCompleted(ctx context.Context, event Event) error {
	e, ok := event.(PaymentCompletedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	workflow, err := o.workflows.FindByOrderID(ctx, e.OrderID)
	if err != nil {
		return fmt.Errorf("find workflow: %w", err)
	}

	workflow.UpdateStep("payment", "completed")
	workflow.Status = "pending_inventory"
	if err := o.workflows.Update(ctx, *workflow); err != nil {
		return fmt.Errorf("update workflow: %w", err)
	}

	// Command the inventory service.
	return o.bus.Publish(ctx, ReserveInventoryCommand{EventMeta: newEventMeta(), OrderID: e.OrderID, Items: workflow.Items})
}

func (o *OrderWorkflowOrchestrator) handlePaymentFailed(ctx context.Context, event Event) error {
	e, ok := event.(PaymentFailedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	workflow, err := o.workflows.FindByOrderID(ctx, e.OrderID)
	if err != nil {
		return fmt.Errorf("find workflow: %w", err)
	}

	workflow.UpdateStep("payment", "failed")
	workflow.Status = "failed"
	if err := o.workflows.Update(ctx, *workflow); err != nil {
		return fmt.Errorf("update workflow: %w", err)
	}

	// Compensating action.
	return o.bus.Publish(ctx, CancelOrderCommand{EventMeta: newEventMeta(), OrderID: e.OrderID, Reason: "Payment failed"})
}

func (o *OrderWorkflowOrchestrator) handleInventoryReserved(ctx context.Context, event Event) error {
	e, ok := event.(InventoryReservedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	workflow, err := o.workflows.FindByOrderID(ctx, e.OrderID)
	if err != nil {
		return fmt.Errorf("find workflow: %w", err)
	}

	workflow.UpdateStep("inventory", "completed")
	workflow.Status = "ready_for_shipping"
	if err := o.workflows.Update(ctx, *workflow); err != nil {
		return fmt.Errorf("update workflow: %w", err)
	}

	// Command the shipping service.
	return o.bus.Publish(ctx, CreateShipmentCommand{EventMeta: newEventMeta(), OrderID: e.OrderID, ShippingAddress: workflow.ShippingAddress})
}

func (o *OrderWorkflowOrchestrator) handleInventoryFailed(ctx context.Context, event Event) error {
	e, ok := event.(InventoryFailedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	workflow, err := o.workflows.FindByOrderID(ctx, e.OrderID)
	if err != nil {
		return fmt.Errorf("find workflow: %w", err)
	}

	workflow.UpdateStep("inventory", "failed")
	workflow.Status = "compensating"
	if err := o.workflows.Update(ctx, *workflow); err != nil {
		return fmt.Errorf("update workflow: %w", err)
	}

	// Compensating actions.
	if err := o.bus.Publish(ctx, RefundPaymentCommand{EventMeta: newEventMeta(), OrderID: e.OrderID}); err != nil {
		return fmt.Errorf("publish refund command: %w", err)
	}
	return o.bus.Publish(ctx, CancelOrderCommand{EventMeta: newEventMeta(), OrderID: e.OrderID, Reason: "Inventory unavailable"})
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Loose Coupling | Services communicate through events, not direct calls |
| Scalability | Easy to add new consumers without changing producers |
| Resilience | Async processing handles temporary failures |
| Audit Trail | Events provide complete history of state changes |
| Real-time | Immediate reaction to business events |

## When to Use

- Microservices needing loose coupling
- Real-time analytics and notifications
- Audit logging requirements
- Complex business workflows
- Event sourcing for complete state history
