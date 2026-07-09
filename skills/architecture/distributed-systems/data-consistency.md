---
name: data-consistency
description: Patterns for maintaining data consistency across distributed services
category: architecture/distributed-systems
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Data Consistency Patterns

## Overview

In distributed systems, maintaining data consistency across services is challenging.
Different consistency models offer trade-offs between availability, performance,
and correctness.

## Consistency Models

```
┌─────────────────────────────────────────────────────────────┐
│              CONSISTENCY SPECTRUM                           │
│                                                             │
│  Strong ◄──────────────────────────────────────► Eventual   │
│                                                             │
│  • Linearizable    • Causal      • Read-your-   • Eventual  │
│  • Sequential      • Session     writes                     │
│                                                             │
│  ◄─── Consistency                    Availability ───►      │
│  ◄─── Latency                        Performance ───►       │
└─────────────────────────────────────────────────────────────┘
```

## Saga Pattern

### Choreography-Based Saga

```go
// Each service listens for events and publishes results.
// No central coordinator.

// Event is any fact a service publishes; Type() is the routing key.
type Event interface {
	Type() string
}

// EventBus is the small consumer-side interface each service depends on.
// A concrete implementation wraps a broker (e.g. GCP Pub/Sub, Kafka).
type EventBus interface {
	Publish(ctx context.Context, event Event) error
	Subscribe(eventType string, handler func(ctx context.Context, event Event) error)
}

type OrderCreatedEvent struct {
	OrderID string
	Items   []OrderItem
	Total   float64
}

func (OrderCreatedEvent) Type() string { return "order.created" }

type PaymentCompletedEvent struct {
	OrderID   string
	PaymentID string
}

func (PaymentCompletedEvent) Type() string { return "payment.completed" }

type PaymentFailedEvent struct {
	OrderID string
	Reason  string
}

func (PaymentFailedEvent) Type() string { return "payment.failed" }

type InventoryReservedEvent struct{ OrderID string }

func (InventoryReservedEvent) Type() string { return "inventory.reserved" }

type InventoryFailedEvent struct {
	OrderID string
	Reason  string
}

func (InventoryFailedEvent) Type() string { return "inventory.failed" }

type RefundRequestedEvent struct{ OrderID string }

func (RefundRequestedEvent) Type() string { return "refund.requested" }

// OrderService drives the saga by reacting to payment and inventory events.
type OrderService struct {
	bus    EventBus
	orders OrderRepository
}

func NewOrderService(bus EventBus, orders OrderRepository) *OrderService {
	s := &OrderService{bus: bus, orders: orders}
	bus.Subscribe("payment.completed", s.handlePaymentCompleted)
	bus.Subscribe("payment.failed", s.handlePaymentFailed)
	bus.Subscribe("inventory.reserved", s.handleInventoryReserved)
	bus.Subscribe("inventory.failed", s.handleInventoryFailed)
	return s
}

func (s *OrderService) CreateOrder(ctx context.Context, data CreateOrderData) (*Order, error) {
	order, err := s.orders.Create(ctx, data, "pending")
	if err != nil {
		return nil, fmt.Errorf("create order: %w", err)
	}

	// Start the saga by publishing the first event.
	if err := s.bus.Publish(ctx, OrderCreatedEvent{OrderID: order.ID, Items: data.Items, Total: data.Total}); err != nil {
		return nil, fmt.Errorf("publish order.created: %w", err)
	}
	return order, nil
}

func (s *OrderService) handlePaymentCompleted(ctx context.Context, event Event) error {
	e, ok := event.(PaymentCompletedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	return s.orders.UpdateStatus(ctx, e.OrderID, "payment_completed")
}

func (s *OrderService) handlePaymentFailed(ctx context.Context, event Event) error {
	e, ok := event.(PaymentFailedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	if err := s.orders.UpdateStatus(ctx, e.OrderID, "payment_failed"); err != nil {
		return fmt.Errorf("mark payment_failed: %w", err)
	}
	// Compensating action: cancel the order.
	return s.cancelOrder(ctx, e.OrderID)
}

func (s *OrderService) handleInventoryReserved(ctx context.Context, event Event) error {
	e, ok := event.(InventoryReservedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	return s.orders.UpdateStatus(ctx, e.OrderID, "confirmed")
}

func (s *OrderService) handleInventoryFailed(ctx context.Context, event Event) error {
	e, ok := event.(InventoryFailedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	// Compensating action: refund the payment.
	if err := s.bus.Publish(ctx, RefundRequestedEvent{OrderID: e.OrderID}); err != nil {
		return fmt.Errorf("publish refund.requested: %w", err)
	}
	return s.orders.UpdateStatus(ctx, e.OrderID, "cancelled")
}

// PaymentService charges and refunds in response to order and refund events.
type PaymentService struct {
	bus      EventBus
	payments PaymentProcessor
}

func NewPaymentService(bus EventBus, payments PaymentProcessor) *PaymentService {
	s := &PaymentService{bus: bus, payments: payments}
	bus.Subscribe("order.created", s.handleOrderCreated)
	bus.Subscribe("refund.requested", s.handleRefundRequested)
	return s
}

func (s *PaymentService) handleOrderCreated(ctx context.Context, event Event) error {
	e, ok := event.(OrderCreatedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}

	payment, err := s.payments.Process(ctx, e.OrderID, e.Total)
	if err != nil {
		// Publish the failure so the order service can compensate.
		return s.bus.Publish(ctx, PaymentFailedEvent{OrderID: e.OrderID, Reason: err.Error()})
	}
	return s.bus.Publish(ctx, PaymentCompletedEvent{OrderID: e.OrderID, PaymentID: payment.ID})
}

func (s *PaymentService) handleRefundRequested(ctx context.Context, event Event) error {
	e, ok := event.(RefundRequestedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}
	if err := s.payments.Refund(ctx, e.OrderID); err != nil {
		return fmt.Errorf("refund order %s: %w", e.OrderID, err)
	}
	return nil
}

// InventoryService reserves stock once payment completes.
type InventoryService struct {
	bus   EventBus
	stock InventoryReserver
}

func NewInventoryService(bus EventBus, stock InventoryReserver) *InventoryService {
	s := &InventoryService{bus: bus, stock: stock}
	bus.Subscribe("payment.completed", s.handlePaymentCompleted)
	return s
}

func (s *InventoryService) handlePaymentCompleted(ctx context.Context, event Event) error {
	e, ok := event.(PaymentCompletedEvent)
	if !ok {
		return fmt.Errorf("unexpected event %T", event)
	}

	if err := s.stock.Reserve(ctx, e.OrderID); err != nil {
		// Publish the failure so the order service can compensate.
		return s.bus.Publish(ctx, InventoryFailedEvent{OrderID: e.OrderID, Reason: err.Error()})
	}
	return s.bus.Publish(ctx, InventoryReservedEvent{OrderID: e.OrderID})
}
```

### Orchestration-Based Saga

```go
// A central saga coordinator manages the workflow.

// SagaStep is one forward action plus its compensation, over shared state T.
type SagaStep[T any] struct {
	Name       string
	Execute    func(ctx context.Context, state *T) error
	Compensate func(ctx context.Context, state *T) error
}

// SagaOrchestrator runs steps in order and compensates in reverse on failure.
type SagaOrchestrator[T any] struct {
	steps    []SagaStep[T]
	executed []SagaStep[T]
	logger   *slog.Logger
}

func NewSagaOrchestrator[T any](logger *slog.Logger) *SagaOrchestrator[T] {
	return &SagaOrchestrator[T]{logger: logger}
}

func (o *SagaOrchestrator[T]) AddStep(step SagaStep[T]) *SagaOrchestrator[T] {
	o.steps = append(o.steps, step)
	return o
}

func (o *SagaOrchestrator[T]) Execute(ctx context.Context, state *T) error {
	for _, step := range o.steps {
		if err := step.Execute(ctx, state); err != nil {
			o.compensate(ctx, state)
			return fmt.Errorf("saga step %q: %w", step.Name, err)
		}
		o.executed = append(o.executed, step)
	}
	return nil
}

// compensate rolls back executed steps in reverse order, best effort.
func (o *SagaOrchestrator[T]) compensate(ctx context.Context, state *T) {
	for i := len(o.executed) - 1; i >= 0; i-- {
		step := o.executed[i]
		if err := step.Compensate(ctx, state); err != nil {
			// Log but keep compensating the remaining steps.
			o.logger.ErrorContext(ctx, "compensation failed", "step", step.Name, "error", err)
		}
	}
}

// OrderSagaContext carries state across every step of the order saga.
type OrderSagaContext struct {
	OrderID       string
	CustomerID    string
	Items         []OrderItem
	Total         float64
	PaymentID     string
	ReservationID string
	ShipmentID    string
}

// Small consumer-side interfaces the saga depends on (accept interfaces).
type orderStore interface {
	Create(ctx context.Context, customerID string, items []OrderItem) (string, error)
	Cancel(ctx context.Context, orderID string) error
}

type paymentGateway interface {
	Charge(ctx context.Context, customerID string, amount float64) (string, error)
	Refund(ctx context.Context, paymentID string) error
}

type inventoryStore interface {
	Reserve(ctx context.Context, items []OrderItem) (string, error)
	Release(ctx context.Context, reservationID string) error
}

type shipmentStore interface {
	Create(ctx context.Context, orderID string, items []OrderItem) (string, error)
	Cancel(ctx context.Context, shipmentID string) error
}

func newOrderSaga(logger *slog.Logger, orders orderStore, payments paymentGateway, inventory inventoryStore, shipping shipmentStore) *SagaOrchestrator[OrderSagaContext] {
	return NewSagaOrchestrator[OrderSagaContext](logger).
		AddStep(SagaStep[OrderSagaContext]{
			Name: "CreateOrder",
			Execute: func(ctx context.Context, s *OrderSagaContext) error {
				id, err := orders.Create(ctx, s.CustomerID, s.Items)
				if err != nil {
					return err
				}
				s.OrderID = id
				return nil
			},
			Compensate: func(ctx context.Context, s *OrderSagaContext) error {
				return orders.Cancel(ctx, s.OrderID)
			},
		}).
		AddStep(SagaStep[OrderSagaContext]{
			Name: "ProcessPayment",
			Execute: func(ctx context.Context, s *OrderSagaContext) error {
				id, err := payments.Charge(ctx, s.CustomerID, s.Total)
				if err != nil {
					return err
				}
				s.PaymentID = id
				return nil
			},
			Compensate: func(ctx context.Context, s *OrderSagaContext) error {
				if s.PaymentID == "" {
					return nil
				}
				return payments.Refund(ctx, s.PaymentID)
			},
		}).
		AddStep(SagaStep[OrderSagaContext]{
			Name: "ReserveInventory",
			Execute: func(ctx context.Context, s *OrderSagaContext) error {
				id, err := inventory.Reserve(ctx, s.Items)
				if err != nil {
					return err
				}
				s.ReservationID = id
				return nil
			},
			Compensate: func(ctx context.Context, s *OrderSagaContext) error {
				if s.ReservationID == "" {
					return nil
				}
				return inventory.Release(ctx, s.ReservationID)
			},
		}).
		AddStep(SagaStep[OrderSagaContext]{
			Name: "CreateShipment",
			Execute: func(ctx context.Context, s *OrderSagaContext) error {
				id, err := shipping.Create(ctx, s.OrderID, s.Items)
				if err != nil {
					return err
				}
				s.ShipmentID = id
				return nil
			},
			Compensate: func(ctx context.Context, s *OrderSagaContext) error {
				if s.ShipmentID == "" {
					return nil
				}
				return shipping.Cancel(ctx, s.ShipmentID)
			},
		})
}

// Usage
func placeOrder(ctx context.Context, saga *SagaOrchestrator[OrderSagaContext], items []OrderItem) error {
	state := &OrderSagaContext{
		CustomerID: "cust-123",
		Items:      items,
		Total:      99.99,
	}
	if err := saga.Execute(ctx, state); err != nil {
		// The saga failed and has already compensated.
		return fmt.Errorf("order saga failed: %w", err)
	}
	return nil
}
```

## Two-Phase Commit (2PC)

```go
// TransactionParticipant votes in phase 1 and acts in phase 2.
type TransactionParticipant interface {
	Prepare(ctx context.Context, txID string) (bool, error)
	Commit(ctx context.Context, txID string) error
	Rollback(ctx context.Context, txID string) error
}

// TwoPhaseCommitCoordinator drives prepare then commit/rollback across participants.
type TwoPhaseCommitCoordinator struct {
	participants []TransactionParticipant
	prepared     []TransactionParticipant
}

func NewTwoPhaseCommitCoordinator(participants ...TransactionParticipant) *TwoPhaseCommitCoordinator {
	return &TwoPhaseCommitCoordinator{participants: participants}
}

func (c *TwoPhaseCommitCoordinator) Execute(ctx context.Context, txID string) error {
	// Phase 1: prepare.
	if !c.preparePhase(ctx, txID) {
		// Phase 2: rollback.
		c.rollbackPhase(ctx, txID)
		return fmt.Errorf("transaction %s aborted", txID)
	}
	// Phase 2: commit.
	if err := c.commitPhase(ctx, txID); err != nil {
		return fmt.Errorf("commit phase: %w", err)
	}
	return nil
}

func (c *TwoPhaseCommitCoordinator) preparePhase(ctx context.Context, txID string) bool {
	for _, p := range c.participants {
		ready, err := p.Prepare(ctx, txID)
		if err != nil || !ready {
			return false
		}
		c.prepared = append(c.prepared, p)
	}
	return true
}

func (c *TwoPhaseCommitCoordinator) commitPhase(ctx context.Context, txID string) error {
	g, ctx := errgroup.WithContext(ctx)
	for _, p := range c.prepared {
		g.Go(func() error {
			if err := p.Commit(ctx, txID); err != nil {
				return fmt.Errorf("commit participant: %w", err)
			}
			return nil
		})
	}
	return g.Wait()
}

func (c *TwoPhaseCommitCoordinator) rollbackPhase(ctx context.Context, txID string) {
	var wg sync.WaitGroup
	for _, p := range c.prepared {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Best effort: roll back every participant, ignoring individual failures.
			_ = p.Rollback(ctx, txID)
		}()
	}
	wg.Wait()
}

// OrderParticipant locks an order during prepare and confirms/cancels in phase 2.
type OrderParticipant struct {
	orders  OrderRepository
	mu      sync.Mutex
	pending map[string]*Order
}

func NewOrderParticipant(orders OrderRepository) *OrderParticipant {
	return &OrderParticipant{orders: orders, pending: make(map[string]*Order)}
}

func (p *OrderParticipant) Prepare(ctx context.Context, txID string) (bool, error) {
	// Validate and lock resources.
	order, err := p.orders.FindByTransactionID(ctx, txID)
	if err != nil {
		return false, fmt.Errorf("find order for tx %s: %w", txID, err)
	}
	if order == nil {
		return false, nil
	}
	if err := p.orders.Lock(ctx, order.ID); err != nil {
		return false, fmt.Errorf("lock order %s: %w", order.ID, err)
	}

	p.mu.Lock()
	p.pending[txID] = order
	p.mu.Unlock()
	return true, nil
}

func (p *OrderParticipant) Commit(ctx context.Context, txID string) error {
	order, ok := p.take(txID)
	if !ok {
		return nil
	}
	if err := p.orders.Confirm(ctx, order.ID); err != nil {
		return fmt.Errorf("confirm order %s: %w", order.ID, err)
	}
	return p.orders.Unlock(ctx, order.ID)
}

func (p *OrderParticipant) Rollback(ctx context.Context, txID string) error {
	order, ok := p.take(txID)
	if !ok {
		return nil
	}
	if err := p.orders.Cancel(ctx, order.ID); err != nil {
		return fmt.Errorf("cancel order %s: %w", order.ID, err)
	}
	return p.orders.Unlock(ctx, order.ID)
}

// take removes and returns the pending order for a transaction, if present.
func (p *OrderParticipant) take(txID string) (*Order, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	order, ok := p.pending[txID]
	if ok {
		delete(p.pending, txID)
	}
	return order, ok
}
```

## Eventual Consistency with Outbox Pattern

```go
// The outbox pattern makes event publishing reliable: the domain write and the
// event row commit in ONE transaction, and a separate poller relays them.
type OutboxMessage struct {
	ID            string
	AggregateType string
	AggregateID   string
	EventType     string
	Payload       json.RawMessage
	CreatedAt     time.Time
	ProcessedAt   *time.Time
}

// OutboxRepository persists and drains outbox rows. Save takes the caller's
// pgx.Tx so the event shares the domain write's transaction.
type OutboxRepository struct {
	pool *pgxpool.Pool
}

func NewOutboxRepository(pool *pgxpool.Pool) *OutboxRepository {
	return &OutboxRepository{pool: pool}
}

func (r *OutboxRepository) Save(ctx context.Context, tx pgx.Tx, msg OutboxMessage) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO outbox (id, aggregate_type, aggregate_id, event_type, payload, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		msg.ID, msg.AggregateType, msg.AggregateID, msg.EventType, msg.Payload, msg.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert outbox message: %w", err)
	}
	return nil
}

// GetUnprocessed claims a batch with FOR UPDATE SKIP LOCKED so many pollers can run.
func (r *OutboxRepository) GetUnprocessed(ctx context.Context, limit int) ([]OutboxMessage, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, aggregate_type, aggregate_id, event_type, payload, created_at, processed_at
		 FROM outbox WHERE processed_at IS NULL
		 ORDER BY created_at ASC LIMIT $1 FOR UPDATE SKIP LOCKED`,
		limit)
	if err != nil {
		return nil, fmt.Errorf("query outbox: %w", err)
	}
	defer rows.Close()

	var messages []OutboxMessage
	for rows.Next() {
		var m OutboxMessage
		if err := rows.Scan(&m.ID, &m.AggregateType, &m.AggregateID, &m.EventType, &m.Payload, &m.CreatedAt, &m.ProcessedAt); err != nil {
			return nil, fmt.Errorf("scan outbox row: %w", err)
		}
		messages = append(messages, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate outbox rows: %w", err)
	}
	return messages, nil
}

func (r *OutboxRepository) MarkProcessed(ctx context.Context, id string) error {
	if _, err := r.pool.Exec(ctx, `UPDATE outbox SET processed_at = NOW() WHERE id = $1`, id); err != nil {
		return fmt.Errorf("mark outbox %s processed: %w", id, err)
	}
	return nil
}

type orderCreatedPayload struct {
	OrderID    string      `json:"orderId"`
	CustomerID string      `json:"customerId"`
	Items      []OrderItem `json:"items"`
	Total      float64     `json:"total"`
}

// OrderService writes the order and its event atomically via the outbox.
type OrderService struct {
	pool   *pgxpool.Pool
	orders OrderRepository
	outbox *OutboxRepository
}

func NewOrderService(pool *pgxpool.Pool, orders OrderRepository, outbox *OutboxRepository) *OrderService {
	return &OrderService{pool: pool, orders: orders, outbox: outbox}
}

func (s *OrderService) CreateOrder(ctx context.Context, data CreateOrderData) (*Order, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) // no-op once Commit succeeds

	// Create the order in this transaction.
	order, err := s.orders.Create(ctx, tx, data)
	if err != nil {
		return nil, fmt.Errorf("create order: %w", err)
	}

	payload, err := json.Marshal(orderCreatedPayload{
		OrderID:    order.ID,
		CustomerID: data.CustomerID,
		Items:      data.Items,
		Total:      data.Total,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal payload: %w", err)
	}

	// Add the event to the outbox in the SAME transaction.
	err = s.outbox.Save(ctx, tx, OutboxMessage{
		ID:            uuid.NewString(),
		AggregateType: "Order",
		AggregateID:   order.ID,
		EventType:     "OrderCreated",
		Payload:       payload,
		CreatedAt:     time.Now(),
	})
	if err != nil {
		return nil, fmt.Errorf("save outbox message: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit tx: %w", err)
	}
	return order, nil
}

// RelayEvent carries an already-serialized outbox payload onto the bus.
type RelayEvent struct {
	eventType string
	payload   json.RawMessage
}

func (e RelayEvent) Type() string { return e.eventType }

// OutboxProcessor relays outbox rows to the bus (a separate process/goroutine).
type OutboxProcessor struct {
	outbox *OutboxRepository
	bus    EventBus
	logger *slog.Logger
}

func NewOutboxProcessor(outbox *OutboxRepository, bus EventBus, logger *slog.Logger) *OutboxProcessor {
	return &OutboxProcessor{outbox: outbox, bus: bus, logger: logger}
}

func (p *OutboxProcessor) process(ctx context.Context) error {
	messages, err := p.outbox.GetUnprocessed(ctx, 100)
	if err != nil {
		return fmt.Errorf("load unprocessed: %w", err)
	}

	for _, msg := range messages {
		if err := p.bus.Publish(ctx, RelayEvent{eventType: msg.EventType, payload: msg.Payload}); err != nil {
			// Log and continue; the row stays unprocessed and retries next tick.
			p.logger.ErrorContext(ctx, "publish outbox message failed", "id", msg.ID, "error", err)
			continue
		}
		if err := p.outbox.MarkProcessed(ctx, msg.ID); err != nil {
			p.logger.ErrorContext(ctx, "mark processed failed", "id", msg.ID, "error", err)
		}
	}
	return nil
}

// StartPolling runs process on an interval until ctx is cancelled (the exit path).
func (p *OutboxProcessor) StartPolling(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := p.process(ctx); err != nil {
				p.logger.ErrorContext(ctx, "outbox poll failed", "error", err)
			}
		}
	}
}
```

## Change Data Capture (CDC)

```go
// CDC (change data capture) with a Debezium-style change event.

type ChangeOperation string

const (
	OpCreate ChangeOperation = "c"
	OpUpdate ChangeOperation = "u"
	OpDelete ChangeOperation = "d"
)

type ChangeSource struct {
	Table     string
	DB        string
	Timestamp int64
}

type ChangeEvent struct {
	Source    ChangeSource
	Operation ChangeOperation
	Before    map[string]any // nil on create
	After     map[string]any // nil on delete
}

// ChangeHandler reacts to one change event.
type ChangeHandler func(ctx context.Context, event ChangeEvent) error

// CDCProcessor fans a change event out to the handlers registered for its table.
type CDCProcessor struct {
	handlers map[string][]ChangeHandler
	logger   *slog.Logger
}

func NewCDCProcessor(logger *slog.Logger) *CDCProcessor {
	return &CDCProcessor{handlers: make(map[string][]ChangeHandler), logger: logger}
}

func (p *CDCProcessor) OnTable(table string, handler ChangeHandler) {
	p.handlers[table] = append(p.handlers[table], handler)
}

func (p *CDCProcessor) ProcessChange(ctx context.Context, event ChangeEvent) {
	for _, handler := range p.handlers[event.Source.Table] {
		if err := handler(ctx, event); err != nil {
			// Log and continue so one handler's failure doesn't stall the rest.
			p.logger.ErrorContext(ctx, "cdc handler failed", "table", event.Source.Table, "error", err)
		}
	}
}

// Usage: sync order data to a search index.
func registerSearchSync(cdc *CDCProcessor, index SearchIndex) {
	cdc.OnTable("orders", func(ctx context.Context, event ChangeEvent) error {
		switch event.Operation {
		case OpCreate, OpUpdate:
			id, _ := event.After["id"].(string)
			if err := index.Upsert(ctx, "orders", id, event.After); err != nil {
				return fmt.Errorf("upsert order %s: %w", id, err)
			}
		case OpDelete:
			id, _ := event.Before["id"].(string)
			if err := index.Delete(ctx, "orders", id); err != nil {
				return fmt.Errorf("delete order %s: %w", id, err)
			}
		}
		return nil
	})
}

// Usage: maintain a materialized view.
func registerStatsView(cdc *CDCProcessor, stats OrderStatsService) {
	cdc.OnTable("order_items", func(ctx context.Context, event ChangeEvent) error {
		row := event.After
		if row == nil {
			row = event.Before
		}
		orderID, _ := row["order_id"].(string)
		if err := stats.Recalculate(ctx, orderID); err != nil {
			return fmt.Errorf("recalculate stats for order %s: %w", orderID, err)
		}
		return nil
	})
}
```

## CQRS with Eventual Consistency

```go
// DomainEvent is a fact emitted by an aggregate; Type() routes projection.
type DomainEvent interface {
	Type() string
}

// EventStore appends domain events for read-model projection.
type EventStore interface {
	Append(ctx context.Context, event DomainEvent) error
}

// OrderCommandHandler applies write commands and emits events (write model).
type OrderCommandHandler struct {
	orders     OrderRepository
	eventStore EventStore
}

func NewOrderCommandHandler(orders OrderRepository, eventStore EventStore) *OrderCommandHandler {
	return &OrderCommandHandler{orders: orders, eventStore: eventStore}
}

func (h *OrderCommandHandler) Handle(ctx context.Context, cmd PlaceOrderCommand) (string, error) {
	order := PlaceOrder(cmd.CustomerID, cmd.Items, cmd.ShippingAddress)

	// Save to the write model.
	if err := h.orders.Save(ctx, order); err != nil {
		return "", fmt.Errorf("save order: %w", err)
	}

	// Publish events so read models can update.
	for _, event := range order.PullDomainEvents() {
		if err := h.eventStore.Append(ctx, event); err != nil {
			return "", fmt.Errorf("append %s: %w", event.Type(), err)
		}
	}
	return order.ID, nil
}

// OrderQueryService reads from denormalized views (read model).
type OrderQueryService struct {
	readDB *pgxpool.Pool
}

func NewOrderQueryService(readDB *pgxpool.Pool) *OrderQueryService {
	return &OrderQueryService{readDB: readDB}
}

func (s *OrderQueryService) GetOrderSummary(ctx context.Context, orderID string) (OrderSummary, error) {
	row := s.readDB.QueryRow(ctx,
		`SELECT id, customer_id, status, total, item_count FROM order_summary_view WHERE id = $1`, orderID)

	var out OrderSummary
	if err := row.Scan(&out.ID, &out.CustomerID, &out.Status, &out.Total, &out.ItemCount); err != nil {
		return OrderSummary{}, fmt.Errorf("scan order summary %s: %w", orderID, err)
	}
	return out, nil
}

func (s *OrderQueryService) GetCustomerOrders(ctx context.Context, customerID string) ([]OrderListItem, error) {
	rows, err := s.readDB.Query(ctx,
		`SELECT order_id, customer_id, status, total, created_at
		 FROM customer_orders_view WHERE customer_id = $1 ORDER BY created_at DESC`, customerID)
	if err != nil {
		return nil, fmt.Errorf("query customer orders: %w", err)
	}
	defer rows.Close()

	var out []OrderListItem
	for rows.Next() {
		var item OrderListItem
		if err := rows.Scan(&item.OrderID, &item.CustomerID, &item.Status, &item.Total, &item.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan customer order: %w", err)
		}
		out = append(out, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate customer orders: %w", err)
	}
	return out, nil
}

// OrderProjector maintains the read models by projecting domain events.
type OrderProjector struct {
	readDB *pgxpool.Pool
}

func NewOrderProjector(readDB *pgxpool.Pool) *OrderProjector {
	return &OrderProjector{readDB: readDB}
}

func (p *OrderProjector) Project(ctx context.Context, event DomainEvent) error {
	switch e := event.(type) {
	case OrderPlacedEvent:
		return p.handleOrderPlaced(ctx, e)
	case OrderShippedEvent:
		return p.handleOrderShipped(ctx, e)
	case OrderDeliveredEvent:
		return p.handleOrderDelivered(ctx, e)
	default:
		return nil // no projection for this event type
	}
}

func (p *OrderProjector) handleOrderPlaced(ctx context.Context, e OrderPlacedEvent) error {
	_, err := p.readDB.Exec(ctx,
		`INSERT INTO order_summary_view (id, customer_id, status, total, item_count, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6)`,
		e.OrderID, e.CustomerID, "placed", e.Total, len(e.Items), e.OccurredOn)
	if err != nil {
		return fmt.Errorf("insert order_summary_view: %w", err)
	}

	_, err = p.readDB.Exec(ctx,
		`INSERT INTO customer_orders_view (order_id, customer_id, status, total, created_at)
		 VALUES ($1, $2, $3, $4, $5)`,
		e.OrderID, e.CustomerID, "placed", e.Total, e.OccurredOn)
	if err != nil {
		return fmt.Errorf("insert customer_orders_view: %w", err)
	}
	return nil
}

func (p *OrderProjector) handleOrderShipped(ctx context.Context, e OrderShippedEvent) error {
	_, err := p.readDB.Exec(ctx,
		`UPDATE order_summary_view SET status = 'shipped', tracking_number = $2, shipped_at = $3 WHERE id = $1`,
		e.OrderID, e.TrackingNumber, e.OccurredOn)
	if err != nil {
		return fmt.Errorf("update order_summary_view: %w", err)
	}

	_, err = p.readDB.Exec(ctx,
		`UPDATE customer_orders_view SET status = 'shipped' WHERE order_id = $1`, e.OrderID)
	if err != nil {
		return fmt.Errorf("update customer_orders_view: %w", err)
	}
	return nil
}

func (p *OrderProjector) handleOrderDelivered(ctx context.Context, e OrderDeliveredEvent) error {
	_, err := p.readDB.Exec(ctx,
		`UPDATE order_summary_view SET status = 'delivered', delivered_at = $2 WHERE id = $1`,
		e.OrderID, e.OccurredOn)
	if err != nil {
		return fmt.Errorf("update order_summary_view: %w", err)
	}
	return nil
}
```

## Conflict Resolution

```go
// Change is one field-level edit; Key identifies the field it touches.
type Change struct {
	Key   string
	Value any
}

// Last-Write-Wins (LWW).
type VersionedEntity struct {
	ID        string
	Version   int
	Timestamp time.Time
	Data      any
}

// LWWConflictResolver keeps whichever entity has the latest timestamp.
type LWWConflictResolver struct{}

func (LWWConflictResolver) Resolve(local, remote VersionedEntity) VersionedEntity {
	// Latest timestamp wins.
	if local.Timestamp.After(remote.Timestamp) {
		return local
	}
	return remote
}

// Merge (for compatible changes).
type MergeableEntity struct {
	ID      string
	Version int
	Changes []Change
}

// MergeConflictError reports the changes that could not be merged automatically.
type MergeConflictError struct {
	Conflicts []Change
}

func (e *MergeConflictError) Error() string {
	return fmt.Sprintf("merge conflict: %d change(s) conflict", len(e.Conflicts))
}

// MergeConflictResolver applies the non-conflicting changes from both sides.
type MergeConflictResolver struct{}

func (r MergeConflictResolver) Resolve(base, local, remote MergeableEntity) (MergeableEntity, error) {
	localChanges := r.diffChanges(base.Changes, local.Changes)
	remoteChanges := r.diffChanges(base.Changes, remote.Changes)

	// Check for conflicts.
	if conflicts := r.findConflicts(localChanges, remoteChanges); len(conflicts) > 0 {
		return MergeableEntity{}, &MergeConflictError{Conflicts: conflicts}
	}

	// Merge non-conflicting changes.
	merged := slices.Clone(base.Changes)
	merged = append(merged, localChanges...)
	merged = append(merged, remoteChanges...)
	return MergeableEntity{
		ID:      base.ID,
		Version: max(local.Version, remote.Version) + 1,
		Changes: merged,
	}, nil
}

// diffChanges returns the changes in next whose key is not already in base.
func (MergeConflictResolver) diffChanges(base, next []Change) []Change {
	baseKeys := make(map[string]struct{}, len(base))
	for _, c := range base {
		baseKeys[c.Key] = struct{}{}
	}
	var out []Change
	for _, c := range next {
		if _, ok := baseKeys[c.Key]; !ok {
			out = append(out, c)
		}
	}
	return out
}

// findConflicts returns changes that touch the same key on both sides.
func (MergeConflictResolver) findConflicts(local, remote []Change) []Change {
	remoteKeys := make(map[string]struct{}, len(remote))
	for _, c := range remote {
		remoteKeys[c.Key] = struct{}{}
	}
	var out []Change
	for _, c := range local {
		if _, ok := remoteKeys[c.Key]; ok {
			out = append(out, c)
		}
	}
	return out
}

// GCounter is a grow-only counter CRDT: each node accumulates its own tally.
type GCounter struct {
	nodeID string
	mu     sync.Mutex
	counts map[string]int
}

func NewGCounter(nodeID string) *GCounter {
	return &GCounter{nodeID: nodeID, counts: make(map[string]int)}
}

func (c *GCounter) Increment(amount int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[c.nodeID] += amount
}

func (c *GCounter) Value() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	total := 0
	for _, n := range c.counts {
		total += n
	}
	return total
}

// Merge takes the per-node maximum — the CRDT join for a G-Counter.
func (c *GCounter) Merge(other *GCounter) {
	other.mu.Lock()
	snapshot := maps.Clone(other.counts)
	other.mu.Unlock()

	c.mu.Lock()
	defer c.mu.Unlock()
	for nodeID, count := range snapshot {
		if count > c.counts[nodeID] {
			c.counts[nodeID] = count
		}
	}
}

// State returns a copy of the per-node counts.
func (c *GCounter) State() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return maps.Clone(c.counts)
}

// LWWRegister is a last-write-wins register CRDT.
type LWWRegister[T any] struct {
	mu        sync.Mutex
	value     T
	timestamp int64 // unix nanoseconds
}

func NewLWWRegister[T any](initial T) *LWWRegister[T] {
	return &LWWRegister[T]{value: initial, timestamp: time.Now().UnixNano()}
}

func (r *LWWRegister[T]) Set(value T) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.value = value
	r.timestamp = time.Now().UnixNano()
}

func (r *LWWRegister[T]) Get() T {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.value
}

// Merge keeps whichever value carries the later timestamp.
func (r *LWWRegister[T]) Merge(other *LWWRegister[T]) {
	other.mu.Lock()
	otherValue, otherTS := other.value, other.timestamp
	other.mu.Unlock()

	r.mu.Lock()
	defer r.mu.Unlock()
	if otherTS > r.timestamp {
		r.value = otherValue
		r.timestamp = otherTS
	}
}
```

## Pattern Selection Guide

| Pattern | Consistency | Performance | Complexity | Use Case |
|---------|-------------|-------------|------------|----------|
| 2PC | Strong | Low | High | Financial transactions |
| Saga | Eventual | High | Medium | Long-running workflows |
| Outbox | Eventual | High | Low | Event publishing |
| CDC | Eventual | Very High | Medium | Data synchronization |
| CRDT | Strong Eventual | High | Medium | Collaborative editing |

## When to Use

- **2PC**: When strong consistency is required and latency is acceptable
- **Saga**: Long-running transactions across services
- **Outbox**: Reliable event publishing with local transactions
- **CDC**: Real-time data synchronization across systems
- **CRDT**: Distributed data with offline support
