---
name: domain-driven-design
description: Domain-Driven Design tactical and strategic patterns
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Domain-Driven Design (DDD)

## Overview

DDD is an approach to software development that centers the
development on programming a domain model with a rich
understanding of the business processes.

## Strategic Design

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
│                 │                 │                         │
└────────┬────────┴────────┬────────┴────────────┬────────────┘
         │                 │                      │
         └────── Events ───┴────── Events ────────┘
```

### Context Mapping Patterns

Each bounded context is its own Go package under `internal/`. Shared concepts
live in a small `sharedkernel` package; everything else is translated at the
boundary.

```go
// file: internal/sharedkernel/types.go
// 1. Shared Kernel — types shared between contexts.
package sharedkernel

type (
	CustomerID string
	ProductID  string
)

// Money is the minimal shared representation passed between contexts.
type Money struct {
	Amount   int64 // minor units, e.g. cents
	Currency string
}

// file: internal/ordering/inventory_acl.go
// 2. Anti-Corruption Layer — translate external concepts into ours.
package ordering

import (
	"context"
	"fmt"
)

// InventoryProduct is how the Inventory context exposes a product.
type InventoryProduct struct {
	ID                string
	Name              string
	Price             int64
	Currency          string
	AvailableQuantity int
}

// InventoryClient is the small port the ACL depends on, declared here in the
// consumer package.
type InventoryClient interface {
	GetProduct(ctx context.Context, productID string) (InventoryProduct, error)
}

// InventoryACL translates the Inventory context into Ordering's own model.
type InventoryACL struct {
	inventory InventoryClient
}

func NewInventoryACL(inventory InventoryClient) *InventoryACL {
	return &InventoryACL{inventory: inventory}
}

func (a *InventoryACL) ProductForOrdering(ctx context.Context, productID string) (*Product, error) {
	ip, err := a.inventory.GetProduct(ctx, productID)
	if err != nil {
		return nil, fmt.Errorf("fetch inventory product %s: %w", productID, err)
	}

	price, err := NewMoney(ip.Price, ip.Currency)
	if err != nil {
		return nil, fmt.Errorf("translate product price: %w", err)
	}

	// Translate to the Ordering context's own Product.
	return NewProduct(ip.ID, ip.Name, price, ip.AvailableQuantity > 0)
}

// file: internal/ordering/events/order_placed.go
// 3. Published Language — a well-documented, versioned integration event.
package events

import "time"

// OrderPlaced is the contract other contexts consume. Treat it as append-only:
// add fields, never repurpose or remove them.
type OrderPlaced struct {
	EventType   string            `json:"eventType"` // always "ORDER_PLACED"
	Version     string            `json:"version"`   // e.g. "1.0"
	OrderID     string            `json:"orderId"`
	CustomerID  string            `json:"customerId"`
	Items       []OrderPlacedItem `json:"items"`
	TotalAmount int64             `json:"totalAmount"`
	Currency    string            `json:"currency"`
	PlacedAt    time.Time         `json:"placedAt"`
}

type OrderPlacedItem struct {
	ProductID       string `json:"productId"`
	Quantity        int    `json:"quantity"`
	PriceAtPurchase int64  `json:"priceAtPurchase"`
}
```

## Tactical Design

### Entities

```go
// file: internal/ordering/order.go
package ordering

import (
	"errors"
	"fmt"
	"time"
)

type OrderStatus int

const (
	OrderStatusDraft OrderStatus = iota
	OrderStatusPending
	OrderStatusConfirmed
	OrderStatusShipped
	OrderStatusCancelled
)

var (
	ErrOrderMustHaveItems  = errors.New("order must have at least one item")
	ErrCannotCancelShipped = errors.New("cannot cancel a shipped order")
	ErrOrderNotFound       = errors.New("order not found")
)

// Order is an entity: it has identity (ID) and a lifecycle. It buffers the
// domain events it raises so the application layer can publish them.
type Order struct {
	id         OrderID
	customerID CustomerID
	items      []OrderItem
	status     OrderStatus
	createdAt  time.Time
	events     []DomainEvent
}

// NewOrder is the factory: it validates invariants and raises the creation event.
func NewOrder(customerID CustomerID, items []OrderItem) (*Order, error) {
	if len(items) == 0 {
		return nil, ErrOrderMustHaveItems
	}

	o := &Order{
		id:         NewOrderID(),
		customerID: customerID,
		items:      items,
		status:     OrderStatusPending,
		createdAt:  time.Now(),
	}
	o.addEvent(OrderCreated{OrderID: o.id, CustomerID: customerID, Total: o.Total(), OccurredAt: time.Now()})
	return o, nil
}

// ReconstituteOrder rebuilds an Order from persisted state; it raises no events.
func ReconstituteOrder(id OrderID, customerID CustomerID, items []OrderItem, status OrderStatus, createdAt time.Time) *Order {
	return &Order{
		id:         id,
		customerID: customerID,
		items:      items,
		status:     status,
		createdAt:  createdAt,
	}
}

func (o *Order) ID() OrderID            { return o.id }
func (o *Order) CustomerID() CustomerID { return o.customerID }
func (o *Order) Status() OrderStatus    { return o.status }
func (o *Order) CreatedAt() time.Time   { return o.createdAt }
func (o *Order) ItemCount() int         { return len(o.items) }

func (o *Order) Total() Money {
	total := Money{Currency: "USD"}
	for _, item := range o.items {
		total.Amount += item.Subtotal().Amount
	}
	return total
}

func (o *Order) Confirm() error {
	if err := o.ensureStatus(OrderStatusPending, "confirm"); err != nil {
		return err
	}
	o.status = OrderStatusConfirmed
	o.addEvent(OrderConfirmed{OrderID: o.id, OccurredAt: time.Now()})
	return nil
}

func (o *Order) Ship(trackingNumber string) error {
	if err := o.ensureStatus(OrderStatusConfirmed, "ship"); err != nil {
		return err
	}
	o.status = OrderStatusShipped
	o.addEvent(OrderShipped{OrderID: o.id, TrackingNumber: trackingNumber, OccurredAt: time.Now()})
	return nil
}

func (o *Order) Cancel(reason string) error {
	if o.status == OrderStatusShipped {
		return ErrCannotCancelShipped
	}
	o.status = OrderStatusCancelled
	o.addEvent(OrderCancelled{OrderID: o.id, Reason: reason, OccurredAt: time.Now()})
	return nil
}

func (o *Order) ensureStatus(expected OrderStatus, action string) error {
	if o.status != expected {
		return fmt.Errorf("cannot %s: order is %v, expected %v", action, o.status, expected)
	}
	return nil
}

func (o *Order) addEvent(event DomainEvent) {
	o.events = append(o.events, event)
}

// PullEvents returns the buffered events and clears the buffer.
func (o *Order) PullEvents() []DomainEvent {
	events := o.events
	o.events = nil
	return events
}
```

### Value Objects

```go
// file: internal/ordering/money.go
package ordering

import (
	"errors"
	"fmt"
)

var (
	ErrNegativeAmount   = errors.New("money amount cannot be negative")
	ErrCurrencyMismatch = errors.New("currency mismatch")
)

// Money is an immutable value object: no identity, compared by value.
type Money struct {
	Amount   int64 // minor units, e.g. cents
	Currency string
}

func NewMoney(amount int64, currency string) (Money, error) {
	if amount < 0 {
		return Money{}, ErrNegativeAmount
	}
	if currency == "" {
		currency = "USD"
	}
	return Money{Amount: amount, Currency: currency}, nil
}

func ZeroMoney(currency string) Money {
	if currency == "" {
		currency = "USD"
	}
	return Money{Currency: currency}
}

func (m Money) Add(other Money) (Money, error) {
	if m.Currency != other.Currency {
		return Money{}, fmt.Errorf("%w: %s vs %s", ErrCurrencyMismatch, m.Currency, other.Currency)
	}
	return Money{Amount: m.Amount + other.Amount, Currency: m.Currency}, nil
}

func (m Money) Subtract(other Money) (Money, error) {
	if m.Currency != other.Currency {
		return Money{}, fmt.Errorf("%w: %s vs %s", ErrCurrencyMismatch, m.Currency, other.Currency)
	}
	return NewMoney(m.Amount-other.Amount, m.Currency)
}

func (m Money) Multiply(factor float64) Money {
	return Money{Amount: int64(float64(m.Amount) * factor), Currency: m.Currency}
}

// Money is a comparable struct, so callers may also use ==; Equals documents intent.
func (m Money) Equals(other Money) bool { return m == other }

func (m Money) String() string {
	return fmt.Sprintf("%s %.2f", m.Currency, float64(m.Amount)/100)
}

// file: internal/ordering/email.go
package ordering

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var (
	emailRegex      = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)
	ErrInvalidEmail = errors.New("invalid email")
)

// Email is a validated, normalized value object.
type Email struct {
	value string
}

func NewEmail(value string) (Email, error) {
	if !emailRegex.MatchString(value) {
		return Email{}, fmt.Errorf("%w: %q", ErrInvalidEmail, value)
	}
	return Email{value: strings.ToLower(value)}, nil
}

func (e Email) Value() string { return e.value }

func (e Email) Domain() string {
	_, domain, _ := strings.Cut(e.value, "@")
	return domain
}

func (e Email) Equals(other Email) bool { return e.value == other.value }

func (e Email) String() string { return e.value }

// file: internal/ordering/address.go
package ordering

import (
	"errors"
	"fmt"
	"strings"
)

// Address is an immutable value object built through a validating constructor.
type Address struct {
	Street  string
	City    string
	State   string
	ZipCode string
	Country string
}

func NewAddress(street, city, state, zipCode, country string) (Address, error) {
	street = strings.TrimSpace(street)
	city = strings.TrimSpace(city)
	zipCode = strings.TrimSpace(zipCode)
	country = strings.TrimSpace(country)

	switch {
	case street == "":
		return Address{}, errors.New("street is required")
	case city == "":
		return Address{}, errors.New("city is required")
	case zipCode == "":
		return Address{}, errors.New("zip code is required")
	case country == "":
		return Address{}, errors.New("country is required")
	}

	return Address{
		Street:  street,
		City:    city,
		State:   strings.TrimSpace(state),
		ZipCode: zipCode,
		Country: country,
	}, nil
}

func (a Address) Equals(other Address) bool { return a == other }

func (a Address) Format() string {
	return fmt.Sprintf("%s, %s, %s %s, %s", a.Street, a.City, a.State, a.ZipCode, a.Country)
}
```

### Aggregates

```go
// file: internal/ordering/order_aggregate.go
package ordering

import (
	"errors"
	"fmt"
)

// Order is the aggregate root; OrderItem is an entity inside the aggregate.
// All access to items goes through the root, which enforces invariants.

const maxOrderTotal = 1_000_000 // minor units

var (
	ErrCannotModifyNonDraft   = errors.New("cannot modify a non-draft order")
	ErrOrderTotalExceedsLimit = errors.New("order total exceeds limit")
	ErrItemNotInOrder         = errors.New("item not in order")
)

// Items returns a defensive copy so callers cannot mutate the aggregate's state.
func (o *Order) Items() []OrderItem {
	items := make([]OrderItem, len(o.items))
	copy(items, o.items)
	return items
}

func (o *Order) AddItem(productID ProductID, quantity int, price Money) error {
	// Guard the invariant at the aggregate boundary.
	if o.status != OrderStatusDraft {
		return ErrCannotModifyNonDraft
	}

	if i := o.indexOfItem(productID); i >= 0 {
		o.items[i].IncreaseQuantity(quantity)
	} else {
		item, err := NewOrderItem(productID, quantity, price)
		if err != nil {
			return fmt.Errorf("add item: %w", err)
		}
		o.items = append(o.items, item)
	}

	// Invariant: order total must not exceed the limit.
	if o.Total().Amount > maxOrderTotal {
		return ErrOrderTotalExceedsLimit
	}
	return nil
}

func (o *Order) RemoveItem(productID ProductID) error {
	if o.status != OrderStatusDraft {
		return ErrCannotModifyNonDraft
	}

	i := o.indexOfItem(productID)
	if i < 0 {
		return fmt.Errorf("%w: product %s", ErrItemNotInOrder, productID)
	}
	o.items = append(o.items[:i], o.items[i+1:]...)
	return nil
}

func (o *Order) indexOfItem(productID ProductID) int {
	for i, item := range o.items {
		if item.ProductID == productID {
			return i
		}
	}
	return -1
}
```

### Domain Services

```go
// file: internal/ordering/pricing.go
package ordering

// DiscountPolicy is a small interface implemented by concrete policies.
type DiscountPolicy interface {
	IsApplicable(order *Order, customer *Customer) bool
	Apply(price Money, order *Order, customer *Customer) Money
}

// PricingService is a stateless domain service: it coordinates logic that does
// not belong to a single entity.
type PricingService struct {
	policies []DiscountPolicy
}

func NewPricingService(policies ...DiscountPolicy) *PricingService {
	return &PricingService{policies: policies}
}

func (s *PricingService) FinalPrice(order *Order, customer *Customer) Money {
	price := order.Total()
	for _, policy := range s.policies {
		if policy.IsApplicable(order, customer) {
			price = policy.Apply(price, order, customer)
		}
	}
	return price
}

// VIPDiscountPolicy gives VIP customers 10% off.
type VIPDiscountPolicy struct{}

func (VIPDiscountPolicy) IsApplicable(_ *Order, customer *Customer) bool { return customer.IsVIP() }
func (VIPDiscountPolicy) Apply(price Money, _ *Order, _ *Customer) Money { return price.Multiply(0.90) }

// BulkOrderDiscountPolicy gives 5% off orders of more than 10 items.
type BulkOrderDiscountPolicy struct{}

func (BulkOrderDiscountPolicy) IsApplicable(order *Order, _ *Customer) bool {
	return order.ItemCount() > 10
}
func (BulkOrderDiscountPolicy) Apply(price Money, _ *Order, _ *Customer) Money {
	return price.Multiply(0.95)
}

// FirstOrderDiscountPolicy gives 15% off a customer's first order.
type FirstOrderDiscountPolicy struct{}

func (FirstOrderDiscountPolicy) IsApplicable(_ *Order, customer *Customer) bool {
	return customer.OrderCount() == 0
}
func (FirstOrderDiscountPolicy) Apply(price Money, _ *Order, _ *Customer) Money {
	return price.Multiply(0.85)
}
```

### Domain Events

```go
// file: internal/ordering/events.go
package ordering

import "time"

// DomainEvent is the small interface every domain event satisfies.
type DomainEvent interface {
	EventType() string
	OccurredOn() time.Time
}

// OrderCreated is raised when an order is created.
type OrderCreated struct {
	OrderID    OrderID
	CustomerID CustomerID
	Total      Money
	OccurredAt time.Time
}

func (OrderCreated) EventType() string       { return "ORDER_CREATED" }
func (e OrderCreated) OccurredOn() time.Time { return e.OccurredAt }

type OrderConfirmed struct {
	OrderID    OrderID
	OccurredAt time.Time
}

func (OrderConfirmed) EventType() string       { return "ORDER_CONFIRMED" }
func (e OrderConfirmed) OccurredOn() time.Time { return e.OccurredAt }

type OrderShipped struct {
	OrderID        OrderID
	TrackingNumber string
	OccurredAt     time.Time
}

func (OrderShipped) EventType() string       { return "ORDER_SHIPPED" }
func (e OrderShipped) OccurredOn() time.Time { return e.OccurredAt }

type OrderCancelled struct {
	OrderID    OrderID
	Reason     string
	OccurredAt time.Time
}

func (OrderCancelled) EventType() string       { return "ORDER_CANCELLED" }
func (e OrderCancelled) OccurredOn() time.Time { return e.OccurredAt }
```

```go
// file: internal/ordering/app/order_created_handler.go
package app

import (
	"context"
	"fmt"

	"example.com/shop/internal/ordering"
	"golang.org/x/sync/errgroup"
)

// The handler depends on small ports declared here in the consumer package.
type (
	EmailService interface {
		SendOrderConfirmation(ctx context.Context, customerID, orderID string) error
	}
	InventoryService interface {
		ReserveItems(ctx context.Context, orderID string) error
	}
	AnalyticsService interface {
		TrackOrderCreated(ctx context.Context, event ordering.OrderCreated) error
	}
)

type OrderCreatedHandler struct {
	email     EmailService
	inventory InventoryService
	analytics AnalyticsService
}

func NewOrderCreatedHandler(email EmailService, inventory InventoryService, analytics AnalyticsService) *OrderCreatedHandler {
	return &OrderCreatedHandler{email: email, inventory: inventory, analytics: analytics}
}

func (h *OrderCreatedHandler) Handle(ctx context.Context, event ordering.OrderCreated) error {
	// Fan out independent side effects, propagating one cancelable context.
	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		return h.email.SendOrderConfirmation(ctx, string(event.CustomerID), string(event.OrderID))
	})
	g.Go(func() error { return h.inventory.ReserveItems(ctx, string(event.OrderID)) })
	g.Go(func() error { return h.analytics.TrackOrderCreated(ctx, event) })

	if err := g.Wait(); err != nil {
		return fmt.Errorf("handle order created: %w", err)
	}
	return nil
}
```

### Repository Pattern

```go
// file: internal/ordering/repository.go
package ordering

import "context"

// OrderRepository is the persistence port. The interface lives with the domain
// (its consumer); the implementation lives in an infrastructure package.
type OrderRepository interface {
	NextID() OrderID
	Save(ctx context.Context, order *Order) error
	FindByID(ctx context.Context, id OrderID) (*Order, error)
	FindByCustomerID(ctx context.Context, customerID CustomerID) ([]*Order, error)
}

// file: internal/ordering/postgres/order_repository.go
package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"example.com/shop/internal/ordering"
)

// PostgresOrderRepository persists orders with pgx.
type PostgresOrderRepository struct {
	pool *pgxpool.Pool
}

func NewPostgresOrderRepository(pool *pgxpool.Pool) *PostgresOrderRepository {
	return &PostgresOrderRepository{pool: pool}
}

func (r *PostgresOrderRepository) NextID() ordering.OrderID { return ordering.NewOrderID() }

func (r *PostgresOrderRepository) Save(ctx context.Context, order *ordering.Order) (err error) {
	// Unit of work: one transaction for the whole aggregate.
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback(ctx)
		}
	}()

	if _, err = tx.Exec(ctx,
		`INSERT INTO orders (id, customer_id, status, created_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (id) DO UPDATE SET status = $3`,
		order.ID(), order.CustomerID(), order.Status(), order.CreatedAt()); err != nil {
		return fmt.Errorf("upsert order: %w", err)
	}

	for _, item := range order.Items() {
		if _, err = tx.Exec(ctx,
			`INSERT INTO order_items (id, order_id, product_id, quantity, price)
			 VALUES ($1, $2, $3, $4, $5)
			 ON CONFLICT (id) DO NOTHING`,
			item.ID(), order.ID(), item.ProductID, item.Quantity(), item.Price().Amount); err != nil {
			return fmt.Errorf("insert order item: %w", err)
		}
	}

	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

func (r *PostgresOrderRepository) FindByID(ctx context.Context, id ordering.OrderID) (*ordering.Order, error) {
	var (
		customerID ordering.CustomerID
		status     ordering.OrderStatus
		createdAt  time.Time
	)
	err := r.pool.QueryRow(ctx,
		`SELECT customer_id, status, created_at FROM orders WHERE id = $1`, id).
		Scan(&customerID, &status, &createdAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ordering.ErrOrderNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("query order %s: %w", id, err)
	}

	items, err := r.loadItems(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("load items for order %s: %w", id, err)
	}
	return ordering.ReconstituteOrder(id, customerID, items, status, createdAt), nil
}

func (r *PostgresOrderRepository) loadItems(ctx context.Context, id ordering.OrderID) ([]ordering.OrderItem, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT product_id, quantity, price FROM order_items WHERE order_id = $1`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []ordering.OrderItem
	for rows.Next() {
		var (
			productID ordering.ProductID
			quantity  int
			price     int64
		)
		if err := rows.Scan(&productID, &quantity, &price); err != nil {
			return nil, err
		}
		item, err := ordering.NewOrderItem(productID, quantity, ordering.Money{Amount: price, Currency: "USD"})
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}
```

### Specification Pattern

```go
// file: internal/ordering/specification.go
package ordering

// Specification expresses a business rule as a composable object.
type Specification[T any] interface {
	IsSatisfiedBy(entity T) bool
}

// And, Or and Not build new specifications from existing ones.
func And[T any](a, b Specification[T]) Specification[T] {
	return specFunc[T](func(e T) bool { return a.IsSatisfiedBy(e) && b.IsSatisfiedBy(e) })
}

func Or[T any](a, b Specification[T]) Specification[T] {
	return specFunc[T](func(e T) bool { return a.IsSatisfiedBy(e) || b.IsSatisfiedBy(e) })
}

func Not[T any](s Specification[T]) Specification[T] {
	return specFunc[T](func(e T) bool { return !s.IsSatisfiedBy(e) })
}

// specFunc adapts a plain func to the Specification interface.
type specFunc[T any] func(T) bool

func (f specFunc[T]) IsSatisfiedBy(e T) bool { return f(e) }

// Concrete specifications.
type OrderPending struct{}

func (OrderPending) IsSatisfiedBy(o *Order) bool { return o.Status() == OrderStatusPending }

type OrderTotalAbove struct {
	Threshold Money
}

func (s OrderTotalAbove) IsSatisfiedBy(o *Order) bool {
	return o.Total().Amount >= s.Threshold.Amount
}

// EligibleOrders combines specifications and filters with them.
func EligibleOrders(orders []*Order, threshold Money) []*Order {
	spec := And[*Order](OrderPending{}, OrderTotalAbove{Threshold: threshold})

	var eligible []*Order
	for _, o := range orders {
		if spec.IsSatisfiedBy(o) {
			eligible = append(eligible, o)
		}
	}
	return eligible
}
```

## Summary

| Concept | Purpose | Example |
|---------|---------|---------|
| Entity | Identity + Lifecycle | Order, User |
| Value Object | Immutable, no identity | Money, Email |
| Aggregate | Consistency boundary | Order + OrderItems |
| Domain Service | Cross-entity logic | PricingService |
| Domain Event | Notify state changes | OrderCreated |
| Repository | Persistence abstraction | OrderRepository |
| Factory | Complex creation | NewOrder() |
| Specification | Business rules as objects | OrderPending |
