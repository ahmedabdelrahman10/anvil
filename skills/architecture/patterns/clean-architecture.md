---
name: clean-architecture
description: Clean Architecture pattern for maintainable systems
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Clean Architecture

## Overview

Clean Architecture separates concerns into concentric layers,
with dependencies pointing inward toward business logic.

## Layer Structure

```
┌─────────────────────────────────────────────────────┐
│                    Frameworks                        │
│  ┌───────────────────────────────────────────────┐  │
│  │              Interface Adapters                │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │           Application Layer              │  │  │
│  │  │  ┌───────────────────────────────────┐  │  │  │
│  │  │  │         Domain Layer              │  │  │  │
│  │  │  │    (Entities & Business Rules)    │  │  │  │
│  │  │  └───────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
           Dependencies point INWARD →
```

## Directory Structure

```
├── cmd/
│   └── shop/
│       └── main.go                # composition root: wire everything by hand
│
└── internal/
    ├── money/                     # Innermost — value object, no dependencies
    │   └── money.go
    │
    ├── order/                     # Domain — entities & business rules
    │   ├── order.go               # Order aggregate + Item + Status + domain errors
    │   └── order_test.go
    │
    ├── product/                   # Domain — product entity
    │   └── product.go
    │
    ├── usecase/                   # Application — use cases + ports (consumer side)
    │   ├── ports.go               # OrderRepository, ProductRepository, EventPublisher
    │   ├── create_order.go        # CreateOrder use case + DTOs
    │   └── get_order.go
    │
    ├── postgres/                  # Infrastructure — driven adapter (pgx)
    │   ├── order_repo.go
    │   └── product_repo.go
    │
    ├── stripe/                    # Infrastructure — payment adapter
    │   └── gateway.go
    │
    ├── pubsub/                    # Infrastructure — event publisher adapter
    │   └── publisher.go
    │
    └── httpapi/                   # Presentation — driving adapter (chi)
        ├── order_handler.go
        └── router.go
```

## Implementation Example

### Domain Layer (Entities)

```go
// internal/order/order.go
package order

import (
	"errors"
	"fmt"
	"time"

	"github.com/example/shop/internal/money"
	"github.com/google/uuid"
)

// Domain errors are sentinels; use cases inspect them with errors.Is.
var (
	ErrEmptyOrder     = errors.New("order must have at least one item")
	ErrNotPending     = errors.New("only pending orders can be modified")
	ErrNotConfirmable = errors.New("only pending orders can be confirmed")
	ErrNotShippable   = errors.New("only confirmed orders can be shipped")
	ErrAlreadyShipped = errors.New("cannot cancel a shipped order")
	ErrOutOfStock     = errors.New("insufficient stock")
)

// Status is the lifecycle state of an order.
type Status string

const (
	StatusPending   Status = "pending"
	StatusConfirmed Status = "confirmed"
	StatusShipped   Status = "shipped"
	StatusCancelled Status = "cancelled"
)

// Item is one line in an order.
type Item struct {
	ProductID string
	Quantity  int64
	Price     money.Money
}

// NewItem builds a line item for a product at a unit price.
func NewItem(productID string, quantity int64, price money.Money) Item {
	return Item{ProductID: productID, Quantity: quantity, Price: price}
}

// Subtotal is unit price times quantity.
func (i Item) Subtotal() money.Money {
	return i.Price.Multiply(i.Quantity)
}

// Order is the aggregate root. Business rules live on the type; the unexported
// fields keep the invariants under the entity's own control.
type Order struct {
	ID         string
	CustomerID string
	CreatedAt  time.Time

	items  []Item
	status Status
}

// New constructs a pending order, enforcing the "at least one item" invariant.
func New(customerID string, items []Item) (*Order, error) {
	if len(items) == 0 {
		return nil, ErrEmptyOrder
	}
	return &Order{
		ID:         uuid.NewString(),
		CustomerID: customerID,
		CreatedAt:  time.Now(),
		items:      items,
		status:     StatusPending,
	}, nil
}

// Reconstruct rebuilds an order from persisted state. Repository adapters use
// it to rehydrate the aggregate without re-running creation invariants.
func Reconstruct(id, customerID string, items []Item, status Status, createdAt time.Time) *Order {
	return &Order{
		ID:         id,
		CustomerID: customerID,
		CreatedAt:  createdAt,
		items:      items,
		status:     status,
	}
}

// Total sums the line items in the order's currency.
func (o *Order) Total() (money.Money, error) {
	if len(o.items) == 0 {
		return money.Money{}, ErrEmptyOrder
	}
	sum := money.Zero(o.items[0].Price.Currency())
	for _, it := range o.items {
		next, err := sum.Add(it.Subtotal())
		if err != nil {
			return money.Money{}, fmt.Errorf("order total: %w", err)
		}
		sum = next
	}
	return sum, nil
}

// Status reports the current lifecycle state.
func (o *Order) Status() Status { return o.status }

// Items returns a defensive copy so callers cannot mutate internal state.
func (o *Order) Items() []Item {
	out := make([]Item, len(o.items))
	copy(out, o.items)
	return out
}

// AddItem appends a line item while the order is still pending.
func (o *Order) AddItem(item Item) error {
	if o.status != StatusPending {
		return ErrNotPending
	}
	o.items = append(o.items, item)
	return nil
}

// Confirm moves a pending order to confirmed.
func (o *Order) Confirm() error {
	if o.status != StatusPending {
		return ErrNotConfirmable
	}
	o.status = StatusConfirmed
	return nil
}

// Ship moves a confirmed order to shipped.
func (o *Order) Ship() error {
	if o.status != StatusConfirmed {
		return ErrNotShippable
	}
	o.status = StatusShipped
	return nil
}

// Cancel cancels any order that has not yet shipped.
func (o *Order) Cancel() error {
	if o.status == StatusShipped {
		return ErrAlreadyShipped
	}
	o.status = StatusCancelled
	return nil
}
```

### Domain Layer (Value Objects)

```go
// internal/money/money.go
package money

import "errors"

// Sentinel errors for invalid money operations.
var (
	ErrNegativeAmount   = errors.New("amount cannot be negative")
	ErrCurrencyMismatch = errors.New("currency mismatch")
)

// Money is an immutable value object holding an amount in minor units (e.g.
// cents). Methods return new values; they never mutate the receiver.
type Money struct {
	amount   int64
	currency string
}

// New builds a Money value, rejecting negative amounts.
func New(amount int64, currency string) (Money, error) {
	if amount < 0 {
		return Money{}, ErrNegativeAmount
	}
	return Money{amount: amount, currency: currency}, nil
}

// Zero returns a zero amount in the given currency.
func Zero(currency string) Money {
	return Money{currency: currency}
}

// Amount reports the amount in minor units.
func (m Money) Amount() int64 { return m.amount }

// Currency reports the ISO 4217 code.
func (m Money) Currency() string { return m.currency }

// Add returns the sum of two same-currency values.
func (m Money) Add(other Money) (Money, error) {
	if m.currency != other.currency {
		return Money{}, ErrCurrencyMismatch
	}
	return Money{amount: m.amount + other.amount, currency: m.currency}, nil
}

// Multiply scales the amount by a whole factor.
func (m Money) Multiply(factor int64) Money {
	return Money{amount: m.amount * factor, currency: m.currency}
}
```

### Domain Layer (Repository Interface)

In Go the port (interface) lives with its **consumer** — the use case — not
alongside the domain entity. The dependency rule still holds: the adapter
depends on this interface, and the use case never depends on the adapter.

```go
// internal/usecase/ports.go
package usecase

import (
	"context"

	"github.com/example/shop/internal/order"
	"github.com/example/shop/internal/product"
)

// OrderRepository persists and loads orders. Kept small and behavioural —
// no implementation details leak into the port.
type OrderRepository interface {
	Save(ctx context.Context, o *order.Order) error
	FindByID(ctx context.Context, id string) (*order.Order, error)
	FindByCustomerID(ctx context.Context, customerID string) ([]*order.Order, error)
	Delete(ctx context.Context, id string) error
}

// ProductRepository loads products referenced by an order.
type ProductRepository interface {
	FindByID(ctx context.Context, id string) (*product.Product, error)
}

// EventPublisher emits domain events to the outside world.
type EventPublisher interface {
	Publish(ctx context.Context, event Event) error
}

// Event is a domain event carried across the boundary.
type Event struct {
	Type    string
	Payload map[string]any
}
```

### Application Layer (Use Case)

```go
// internal/usecase/create_order.go
package usecase

import (
	"context"
	"fmt"

	"github.com/example/shop/internal/order"
)

// CreateOrderInput is the DTO crossing into the use case.
type CreateOrderInput struct {
	CustomerID string
	Items      []OrderItemInput
}

// OrderItemInput is one requested line item.
type OrderItemInput struct {
	ProductID string
	Quantity  int64
}

// OrderResponse is the DTO crossing back out — never the domain entity.
type OrderResponse struct {
	OrderID  string
	Total    int64
	Currency string
	Status   string
}

// CreateOrder is a use case. It depends only on ports (interfaces) injected via
// the constructor — no framework, no globals, no init().
type CreateOrder struct {
	orders   OrderRepository
	products ProductRepository
	events   EventPublisher
}

// NewCreateOrder wires the use case with its ports.
func NewCreateOrder(orders OrderRepository, products ProductRepository, events EventPublisher) *CreateOrder {
	return &CreateOrder{orders: orders, products: products, events: events}
}

// Execute validates stock, builds the domain order, persists it, and emits an event.
func (uc *CreateOrder) Execute(ctx context.Context, in CreateOrderInput) (OrderResponse, error) {
	items := make([]order.Item, 0, len(in.Items))
	for _, want := range in.Items {
		p, err := uc.products.FindByID(ctx, want.ProductID)
		if err != nil {
			return OrderResponse{}, fmt.Errorf("load product %s: %w", want.ProductID, err)
		}
		if !p.HasStock(want.Quantity) {
			return OrderResponse{}, fmt.Errorf("%s: %w", p.Name, order.ErrOutOfStock)
		}
		items = append(items, order.NewItem(p.ID, want.Quantity, p.Price))
	}

	o, err := order.New(in.CustomerID, items)
	if err != nil {
		return OrderResponse{}, fmt.Errorf("create order: %w", err)
	}

	if err := uc.orders.Save(ctx, o); err != nil {
		return OrderResponse{}, fmt.Errorf("save order: %w", err)
	}

	total, err := o.Total()
	if err != nil {
		return OrderResponse{}, fmt.Errorf("compute total: %w", err)
	}

	event := Event{
		Type: "ORDER_CREATED",
		Payload: map[string]any{
			"orderId":    o.ID,
			"customerId": o.CustomerID,
		},
	}
	if err := uc.events.Publish(ctx, event); err != nil {
		return OrderResponse{}, fmt.Errorf("publish order created: %w", err)
	}

	return OrderResponse{
		OrderID:  o.ID,
		Total:    total.Amount(),
		Currency: total.Currency(),
		Status:   string(o.Status()),
	}, nil
}
```

### Infrastructure Layer (Repository Implementation)

```go
// internal/postgres/order_repo.go
package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/example/shop/internal/money"
	"github.com/example/shop/internal/order"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// OrderRepo is a pgx-backed adapter that satisfies usecase.OrderRepository.
// It returns a concrete struct; callers depend on the interface.
type OrderRepo struct {
	pool *pgxpool.Pool
}

// NewOrderRepo builds a repository over an existing pool.
func NewOrderRepo(pool *pgxpool.Pool) *OrderRepo {
	return &OrderRepo{pool: pool}
}

// Save upserts the order and its items in a single transaction.
func (r *OrderRepo) Save(ctx context.Context, o *order.Order) error {
	total, err := o.Total()
	if err != nil {
		return fmt.Errorf("order total: %w", err)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	const upsertOrder = `
		INSERT INTO orders (id, customer_id, status, total_amount, total_currency, created_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO UPDATE SET
			status = EXCLUDED.status,
			total_amount = EXCLUDED.total_amount,
			updated_at = NOW()`
	if _, err := tx.Exec(ctx, upsertOrder,
		o.ID, o.CustomerID, string(o.Status()),
		total.Amount(), total.Currency(), o.CreatedAt,
	); err != nil {
		return fmt.Errorf("upsert order %s: %w", o.ID, err)
	}

	const insItem = `
		INSERT INTO order_items (order_id, product_id, quantity, price, currency)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (order_id, product_id) DO NOTHING`
	for _, it := range o.Items() {
		if _, err := tx.Exec(ctx, insItem,
			o.ID, it.ProductID, it.Quantity, it.Price.Amount(), it.Price.Currency(),
		); err != nil {
			return fmt.Errorf("insert item %s: %w", it.ProductID, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

// FindByID loads an order and its items, or (nil, nil) when absent.
func (r *OrderRepo) FindByID(ctx context.Context, id string) (*order.Order, error) {
	const q = `SELECT customer_id, status, created_at FROM orders WHERE id = $1`
	var (
		customerID string
		status     string
		createdAt  time.Time
	)
	err := r.pool.QueryRow(ctx, q, id).Scan(&customerID, &status, &createdAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, fmt.Errorf("find order %s: %w", id, err)
	}

	items, err := r.loadItems(ctx, id)
	if err != nil {
		return nil, err
	}
	return order.Reconstruct(id, customerID, items, order.Status(status), createdAt), nil
}

// FindByCustomerID lists a customer's orders, newest first.
func (r *OrderRepo) FindByCustomerID(ctx context.Context, customerID string) ([]*order.Order, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, status, created_at FROM orders WHERE customer_id = $1 ORDER BY created_at DESC`,
		customerID)
	if err != nil {
		return nil, fmt.Errorf("query orders for %s: %w", customerID, err)
	}

	// Drain the header rows before issuing per-order item queries: a single
	// pgx connection cannot run a new query while a Rows is still open.
	type header struct {
		id        string
		status    string
		createdAt time.Time
	}
	var headers []header
	for rows.Next() {
		var h header
		if err := rows.Scan(&h.id, &h.status, &h.createdAt); err != nil {
			rows.Close()
			return nil, fmt.Errorf("scan order: %w", err)
		}
		headers = append(headers, h)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate orders: %w", err)
	}

	orders := make([]*order.Order, 0, len(headers))
	for _, h := range headers {
		items, err := r.loadItems(ctx, h.id)
		if err != nil {
			return nil, err
		}
		orders = append(orders, order.Reconstruct(h.id, customerID, items, order.Status(h.status), h.createdAt))
	}
	return orders, nil
}

// Delete removes an order by id.
func (r *OrderRepo) Delete(ctx context.Context, id string) error {
	if _, err := r.pool.Exec(ctx, `DELETE FROM orders WHERE id = $1`, id); err != nil {
		return fmt.Errorf("delete order %s: %w", id, err)
	}
	return nil
}

// loadItems reads the line items for one order and maps them to the domain.
func (r *OrderRepo) loadItems(ctx context.Context, orderID string) ([]order.Item, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT product_id, quantity, price, currency FROM order_items WHERE order_id = $1`,
		orderID)
	if err != nil {
		return nil, fmt.Errorf("query items for %s: %w", orderID, err)
	}
	defer rows.Close()

	var items []order.Item
	for rows.Next() {
		var (
			productID string
			quantity  int64
			price     int64
			currency  string
		)
		if err := rows.Scan(&productID, &quantity, &price, &currency); err != nil {
			return nil, fmt.Errorf("scan item: %w", err)
		}
		m, err := money.New(price, currency)
		if err != nil {
			return nil, fmt.Errorf("item price: %w", err)
		}
		items = append(items, order.NewItem(productID, quantity, m))
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate items: %w", err)
	}
	return items, nil
}
```

### Presentation Layer (HTTP Handler)

```go
// internal/httpapi/order_handler.go
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/example/shop/internal/order"
	"github.com/example/shop/internal/usecase"
	"github.com/go-chi/chi/v5"
)

// createOrderExecutor is the small input port this handler consumes. Declaring
// it here (in the consumer) keeps the handler decoupled from the use case type.
type createOrderExecutor interface {
	Execute(ctx context.Context, in usecase.CreateOrderInput) (usecase.OrderResponse, error)
}

// getOrderExecutor loads a single order.
type getOrderExecutor interface {
	Execute(ctx context.Context, id string) (usecase.OrderResponse, error)
}

// OrderHandler adapts HTTP to the use cases. It holds interfaces, not structs.
type OrderHandler struct {
	create createOrderExecutor
	get    getOrderExecutor
}

// NewOrderHandler wires the handler with its use cases.
func NewOrderHandler(create createOrderExecutor, get getOrderExecutor) *OrderHandler {
	return &OrderHandler{create: create, get: get}
}

// Routes mounts the order endpoints on a chi router.
func (h *OrderHandler) Routes(r chi.Router) {
	r.Post("/orders", h.Create)
	r.Get("/orders/{id}", h.Get)
}

type createOrderRequest struct {
	CustomerID string `json:"customer_id"`
	Items      []struct {
		ProductID string `json:"product_id"`
		Quantity  int64  `json:"quantity"`
	} `json:"items"`
}

// Create decodes the request, invokes the use case, and encodes the response.
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}

	in := usecase.CreateOrderInput{CustomerID: req.CustomerID}
	for _, it := range req.Items {
		in.Items = append(in.Items, usecase.OrderItemInput{
			ProductID: it.ProductID,
			Quantity:  it.Quantity,
		})
	}

	resp, err := h.create.Execute(r.Context(), in)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, resp)
}

// Get returns a single order by id.
func (h *OrderHandler) Get(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	resp, err := h.get.Execute(r.Context(), id)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError maps domain errors to HTTP status codes — the boundary owns the codes.
func writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, order.ErrEmptyOrder), errors.Is(err, order.ErrOutOfStock):
		http.Error(w, err.Error(), http.StatusBadRequest)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
```

## Dependency Injection Setup

The composition root wires interfaces to implementations by hand — plain
constructor injection, no container. For larger graphs, generate the wiring
with `google/wire` (compile-time DI) rather than a runtime reflection container.

```go
// cmd/shop/main.go
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/example/shop/internal/httpapi"
	"github.com/example/shop/internal/postgres"
	"github.com/example/shop/internal/pubsub"
	"github.com/example/shop/internal/usecase"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// run builds the object graph inward-out: adapters, then use cases, then the
// delivery layer. Each dependency is passed explicitly through a constructor.
func run() error {
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	defer pool.Close()

	// Infrastructure adapters (concrete structs) satisfy the ports the use
	// cases declare.
	orders := postgres.NewOrderRepo(pool)
	products := postgres.NewProductRepo(pool)
	events := pubsub.NewPublisher()

	// Application use cases depend only on interfaces, injected here.
	createOrder := usecase.NewCreateOrder(orders, products, events)
	getOrder := usecase.NewGetOrder(orders)

	// Presentation adapter.
	handler := httpapi.NewOrderHandler(createOrder, getOrder)

	r := chi.NewRouter()
	handler.Routes(r)

	log.Println("listening on :8080")
	return http.ListenAndServe(":8080", r)
}
```

## The Dependency Rule

```
OUTER layers can depend on INNER layers
INNER layers NEVER depend on OUTER layers

✅ HTTP Handler → Use Case → Entity
✅ Repository adapter → Repository port (interface)
❌ Entity → Repository adapter
❌ Use Case → HTTP Handler
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Testability | Business logic easily unit tested |
| Flexibility | Swap implementations without affecting core |
| Maintainability | Clear separation of concerns |
| Independence | Framework/database agnostic core |

## Rules Summary

1. **Dependencies point inward** - Outer layers depend on inner, never reverse
2. **Domain has no dependencies** - Pure business logic only
3. **Use interfaces at boundaries** - Small ports declared in the consumer package
4. **DTOs cross boundaries** - Never expose domain entities
5. **Framework code in outer layers** - Keep frameworks out of domain
