# Architecture Patterns Reference

## Clean Architecture

### Layer Structure

```
internal/
├── domain/                    # Innermost — business logic
│   ├── entity/                # Core business objects (structs + methods)
│   ├── valueobject/           # Immutable value types
│   ├── repository/            # Interfaces only!
│   ├── service/               # Domain services
│   └── domainerr/             # Domain errors
│
├── app/                       # Use cases
│   ├── usecase/               # Application services
│   ├── dto/                   # Data transfer objects
│   ├── mapper/                # Entity <-> DTO mapping
│   └── port/                  # Ports for external services
│
├── infra/                     # External implementations
│   ├── persistence/           # Database implementations
│   ├── external/              # Third-party integrations
│   ├── cache/                 # Caching layer
│   └── config/                # Configuration
│
└── transport/                 # Outermost — delivery
    ├── httpapi/               # REST/HTTP handlers
    ├── grpcapi/               # gRPC servers
    └── cli/                   # CLI commands
```

### Dependency Rule

```
OUTER layers can depend on INNER layers
INNER layers NEVER depend on OUTER layers

✅ Handler → Use Case → Entity
✅ Repository Impl → Repository Interface
❌ Entity → Repository Implementation
❌ Use Case → Handler
```

### Implementation Example

```go
// Domain entity
type Order struct {
	id     string
	items  []OrderItem
	status OrderStatus
}

func NewOrder(items []OrderItem) (*Order, error) {
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: order must have items", ErrDomain)
	}
	return &Order{id: uuid.NewString(), items: items, status: OrderStatusPending}, nil
}

func (o *Order) ID() string { return o.id }

func (o *Order) Total() Money {
	total := ZeroMoney()
	for _, it := range o.items {
		total = total.Add(it.Subtotal())
	}
	return total
}

func (o *Order) Confirm() error {
	if o.status != OrderStatusPending {
		return fmt.Errorf("%w: only pending orders can be confirmed", ErrDomain)
	}
	o.status = OrderStatusConfirmed
	return nil
}

// Domain repository interface (declared in the domain package)
type OrderRepository interface {
	Save(ctx context.Context, o *Order) error
	FindByID(ctx context.Context, id string) (*Order, error)
}

// Application use case
type CreateOrderUseCase struct{ orders OrderRepository }

func NewCreateOrderUseCase(orders OrderRepository) *CreateOrderUseCase {
	return &CreateOrderUseCase{orders: orders}
}

func (uc *CreateOrderUseCase) Execute(ctx context.Context, dto CreateOrderDTO) (OrderResponseDTO, error) {
	items := make([]OrderItem, 0, len(dto.Items))
	for _, i := range dto.Items {
		item, err := NewOrderItem(i.ProductID, i.Quantity, i.Price)
		if err != nil {
			return OrderResponseDTO{}, fmt.Errorf("build item: %w", err)
		}
		items = append(items, item)
	}
	order, err := NewOrder(items)
	if err != nil {
		return OrderResponseDTO{}, fmt.Errorf("create order: %w", err)
	}
	if err := uc.orders.Save(ctx, order); err != nil {
		return OrderResponseDTO{}, fmt.Errorf("save order: %w", err)
	}
	return toOrderDTO(order), nil
}

// Infrastructure repository implementation
type PrismaOrderRepository struct{ db *sql.DB }

func NewPrismaOrderRepository(db *sql.DB) *PrismaOrderRepository {
	return &PrismaOrderRepository{db: db}
}

func (r *PrismaOrderRepository) Save(ctx context.Context, o *Order) error {
	if _, err := r.db.ExecContext(ctx, "INSERT INTO orders ...", toRow(o)); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	return nil
}

func (r *PrismaOrderRepository) FindByID(ctx context.Context, id string) (*Order, error) {
	row := r.db.QueryRowContext(ctx, "SELECT * FROM orders WHERE id = $1", id)
	o, err := scanOrder(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find order %s: %w", id, err)
	}
	return o, nil
}

// Presentation HTTP handler
type OrderHandler struct{ createOrder *CreateOrderUseCase }

func NewOrderHandler(createOrder *CreateOrderUseCase) *OrderHandler {
	return &OrderHandler{createOrder: createOrder}
}

func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	dto, err := decodeCreateOrder(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	res, err := h.createOrder.Execute(r.Context(), dto)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(res)
}
```

## Domain-Driven Design

### Building Blocks

```go
// Value object — immutable, compared by value
type Money struct {
	amount   int64 // minor units, e.g. cents
	currency string
}

func NewMoney(amount int64, currency string) (Money, error) {
	if amount < 0 {
		return Money{}, errors.New("amount cannot be negative")
	}
	return Money{amount: amount, currency: currency}, nil
}

func (m Money) Add(other Money) (Money, error) {
	if m.currency != other.currency {
		return Money{}, fmt.Errorf("currency mismatch: %s vs %s", m.currency, other.currency)
	}
	return Money{amount: m.amount + other.amount, currency: m.currency}, nil
}

func (m Money) Equals(other Money) bool {
	return m.amount == other.amount && m.currency == other.currency
}

// Entity — identity + lifecycle; the aggregate root guards its invariants.
type Order struct {
	id     OrderID
	items  []OrderItem
	status OrderStatus
}

// Items returns a defensive copy so callers can't mutate internal state.
func (o *Order) Items() []OrderItem { return slices.Clone(o.items) }

func (o *Order) AddItem(productID ProductID, quantity int, price Money) error {
	if o.status != OrderStatusDraft {
		return fmt.Errorf("%w: cannot modify non-draft order", ErrDomain)
	}
	item, err := NewOrderItem(productID, quantity, price)
	if err != nil {
		return fmt.Errorf("add item: %w", err)
	}
	o.items = append(o.items, item)
	return nil
}

// Domain event
type OrderCreatedEvent struct {
	OrderID    OrderID
	CustomerID CustomerID
	Total      Money
	OccurredOn time.Time
}

func (OrderCreatedEvent) EventType() string { return "ORDER_CREATED" }

// Domain service — cross-entity logic
type DiscountPolicy interface {
	Applicable(o *Order, c *Customer) bool
	Apply(price Money) Money
}

type PricingService struct{ policies []DiscountPolicy }

func NewPricingService(policies ...DiscountPolicy) *PricingService {
	return &PricingService{policies: policies}
}

func (s *PricingService) FinalPrice(o *Order, c *Customer) Money {
	price := o.Total()
	for _, p := range s.policies {
		if p.Applicable(o, c) {
			price = p.Apply(price)
		}
	}
	return price
}
```

### Bounded Contexts

```
┌─────────────────────────────────────────────────────────────┐
│                      E-Commerce System                       │
├─────────────────┬─────────────────┬─────────────────────────┤
│   Ordering BC   │   Shipping BC   │    Inventory BC         │
│                 │                 │                         │
│  • Order        │  • Shipment     │  • Product              │
│  • OrderItem    │  • Carrier      │  • Stock                │
│  • Customer     │  • Address      │  • Warehouse            │
│    (snapshot)   │  • Package      │  • Location             │
└────────┬────────┴────────┬────────┴────────────┬────────────┘
         └────── Events ───┴────── Events ────────┘
```

### Anti-Corruption Layer

```go
// Translate between bounded contexts.
type InventoryClient interface {
	GetProduct(ctx context.Context, id string) (InventoryProduct, error)
}

type InventoryACL struct{ inventory InventoryClient }

func NewInventoryACL(inventory InventoryClient) *InventoryACL {
	return &InventoryACL{inventory: inventory}
}

func (a *InventoryACL) ProductForOrdering(ctx context.Context, productID string) (OrderingProduct, error) {
	p, err := a.inventory.GetProduct(ctx, productID)
	if err != nil {
		return OrderingProduct{}, fmt.Errorf("fetch inventory product %s: %w", productID, err)
	}
	price, err := NewMoney(p.Price, p.Currency)
	if err != nil {
		return OrderingProduct{}, fmt.Errorf("translate price: %w", err)
	}
	// Translate into the Ordering context's own concept.
	return OrderingProduct{
		ID:        p.ID,
		Name:      p.Name,
		Price:     price,
		Available: p.AvailableQuantity > 0,
	}, nil
}
```

## CQRS + Event Sourcing

### CQRS Pattern

```go
// Command side — writes
type CommandHandler[T any] interface {
	Execute(ctx context.Context, cmd T) error
}

type CreateOrderHandler struct{ orders OrderRepository }

func (h *CreateOrderHandler) Execute(ctx context.Context, cmd CreateOrderCommand) error {
	order, err := NewOrder(cmd.CustomerID, cmd.Items)
	if err != nil {
		return fmt.Errorf("create order: %w", err)
	}
	if err := h.orders.Save(ctx, order); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	return nil
}

// Query side — reads
type QueryHandler[T, R any] interface {
	Execute(ctx context.Context, query T) (R, error)
}

type GetOrderDetailsHandler struct{ read *sql.DB }

func (h *GetOrderDetailsHandler) Execute(ctx context.Context, q GetOrderDetailsQuery) (OrderDetails, error) {
	row := h.read.QueryRowContext(ctx, "SELECT * FROM order_details_view WHERE id = $1", q.OrderID)
	details, err := scanOrderDetails(row)
	if err != nil {
		return OrderDetails{}, fmt.Errorf("get order details %s: %w", q.OrderID, err)
	}
	return details, nil
}
```

### Event Sourcing

```go
// Store events as the source of truth.
type DomainEvent interface {
	EventType() string
	AggregateID() string
	OccurredOn() time.Time
}

type Order struct {
	id      string
	status  OrderStatus
	items   []OrderItem
	changes []DomainEvent // uncommitted events
}

func NewOrder(customerID string, items []OrderItem) *Order {
	o := &Order{}
	o.apply(OrderCreatedEvent{OrderID: uuid.NewString(), CustomerID: customerID, Items: items})
	return o
}

func (o *Order) Confirm() error {
	if o.status != OrderStatusPending {
		return errors.New("cannot confirm non-pending order")
	}
	o.apply(OrderConfirmedEvent{OrderID: o.id})
	return nil
}

// apply records a new event, then mutates state via when.
func (o *Order) apply(e DomainEvent) {
	o.when(e)
	o.changes = append(o.changes, e)
}

// when rebuilds state from an event (no side effects).
func (o *Order) when(e DomainEvent) {
	switch ev := e.(type) {
	case OrderCreatedEvent:
		o.id, o.items, o.status = ev.OrderID, ev.Items, OrderStatusPending
	case OrderConfirmedEvent:
		o.status = OrderStatusConfirmed
	}
}

// Event store
type EventStore interface {
	Save(ctx context.Context, events []DomainEvent) error
	Events(ctx context.Context, aggregateID string) ([]DomainEvent, error)
}

// Rebuild an aggregate from its event history.
func LoadOrder(ctx context.Context, id string, store EventStore) (*Order, error) {
	events, err := store.Events(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("load events %s: %w", id, err)
	}
	o := &Order{}
	for _, e := range events {
		o.when(e)
	}
	return o, nil
}
```

## Microservices

### Service Structure

```
services/
├── order-service/
│   ├── cmd/
│   │   └── server/main.go
│   ├── internal/
│   │   ├── domain/
│   │   ├── app/
│   │   ├── infra/
│   │   └── transport/
│   ├── Dockerfile
│   └── go.mod
├── inventory-service/
├── payment-service/
└── notification-service/
```

### Inter-Service Communication

```go
// Synchronous — REST/gRPC client wrapped with a circuit breaker.
type ProductServiceClient struct {
	http    *http.Client
	breaker *CircuitBreaker
	baseURL string
}

func NewProductServiceClient(baseURL string, breaker *CircuitBreaker) *ProductServiceClient {
	return &ProductServiceClient{http: http.DefaultClient, breaker: breaker, baseURL: baseURL}
}

func (c *ProductServiceClient) GetProduct(ctx context.Context, id string) (Product, error) {
	var p Product
	err := c.breaker.Execute(ctx, func(ctx context.Context) error {
		return getJSON(ctx, c.http, c.baseURL+"/products/"+id, &p)
	})
	if err != nil {
		return Product{}, fmt.Errorf("get product %s: %w", id, err)
	}
	return p, nil
}

// Asynchronous — publish events to a broker.
type MessageBroker interface {
	Publish(ctx context.Context, topic string, msg any) error
}

type OrderEventPublisher struct{ broker MessageBroker }

func NewOrderEventPublisher(broker MessageBroker) *OrderEventPublisher {
	return &OrderEventPublisher{broker: broker}
}

func (p *OrderEventPublisher) PublishOrderCreated(ctx context.Context, o *Order) error {
	evt := OrderCreatedEvent{OrderID: o.ID(), CustomerID: o.CustomerID(), Items: o.Items(), Total: o.Total()}
	if err := p.broker.Publish(ctx, "order.created", evt); err != nil {
		return fmt.Errorf("publish order.created: %w", err)
	}
	return nil
}

// Event consumer — a plain method wired to a subscription at startup
// via broker.Subscribe("order.created", consumer.OnOrderCreated).
type OrderEventsConsumer struct{ notifications NotificationService }

func (c *OrderEventsConsumer) OnOrderCreated(ctx context.Context, evt OrderCreatedEvent) error {
	if err := c.notifications.SendOrderConfirmation(ctx, evt); err != nil {
		return fmt.Errorf("send confirmation: %w", err)
	}
	return nil
}
```

### Saga Pattern (Distributed Transactions)

```go
type SagaStep struct {
	Name       string
	Execute    func(ctx context.Context, sc *SagaContext) error
	Compensate func(ctx context.Context, sc *SagaContext) error
}

type CreateOrderSaga struct{ steps []SagaStep }

func NewCreateOrderSaga(inv InventoryService, pay PaymentService, orders OrderRepository) *CreateOrderSaga {
	return &CreateOrderSaga{steps: []SagaStep{
		{
			Name: "reserve_inventory",
			Execute: func(ctx context.Context, sc *SagaContext) (err error) {
				sc.ReservationID, err = inv.Reserve(ctx, sc.Items)
				return
			},
			Compensate: func(ctx context.Context, sc *SagaContext) error { return inv.CancelReservation(ctx, sc.ReservationID) },
		},
		{
			Name: "process_payment",
			Execute: func(ctx context.Context, sc *SagaContext) (err error) {
				sc.PaymentID, err = pay.Charge(ctx, sc.CustomerID, sc.Total)
				return
			},
			Compensate: func(ctx context.Context, sc *SagaContext) error { return pay.Refund(ctx, sc.PaymentID) },
		},
		{
			Name:       "confirm_order",
			Execute:    func(ctx context.Context, sc *SagaContext) error { return orders.Confirm(ctx, sc.OrderID) },
			Compensate: func(ctx context.Context, sc *SagaContext) error { return orders.Cancel(ctx, sc.OrderID) },
		},
	}}
}

func (s *CreateOrderSaga) Execute(ctx context.Context, cmd CreateOrderCommand) error {
	sc := &SagaContext{CreateOrderCommand: cmd}
	var completed []SagaStep
	for _, step := range s.steps {
		if err := step.Execute(ctx, sc); err != nil {
			for i := len(completed) - 1; i >= 0; i-- { // compensate in reverse order
				if cerr := completed[i].Compensate(ctx, sc); cerr != nil {
					slog.ErrorContext(ctx, "compensation failed", "step", completed[i].Name, "err", cerr)
				}
			}
			return fmt.Errorf("saga step %q: %w", step.Name, err)
		}
		completed = append(completed, step)
	}
	return nil
}
```

### API Gateway

```go
type Route struct {
	Path       string
	Service    string
	Middleware []string
}

func defaultRoutes() []Route {
	return []Route{
		{Path: "/api/users/", Service: "user-service", Middleware: []string{"auth", "rateLimit"}},
		{Path: "/api/orders/", Service: "order-service", Middleware: []string{"auth", "rateLimit"}},
		{Path: "/api/products/", Service: "product-service", Middleware: []string{"rateLimit"}}, // public
	}
}
```

## Pattern Selection Guide

| Scenario | Recommended Pattern |
|----------|-------------------|
| Simple CRUD app | Layered Architecture |
| Complex business rules | Clean/Hexagonal + DDD |
| Large team (10+ devs) | Microservices |
| High read/write asymmetry | CQRS |
| Audit requirements | Event Sourcing |
| Async workflows | Event-Driven Architecture |
| Medium complexity, single team | Modular Monolith |
