---
name: hexagonal-architecture
description: Ports and Adapters pattern for flexible system boundaries
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Hexagonal Architecture (Ports & Adapters)

## Overview

Hexagonal Architecture, also known as Ports and Adapters, isolates the
application core from external concerns through well-defined interfaces.

## Core Concepts

```
                    Driving Adapters (Primary)
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
       ┌─────────┐   ┌─────────┐   ┌─────────┐
       │  HTTP   │   │  CLI    │   │  Events │
       │ Adapter │   │ Adapter │   │ Adapter │
       └────┬────┘   └────┬────┘   └────┬────┘
            │             │             │
            └──────┬──────┴──────┬──────┘
                   │             │
              ┌────▼─────────────▼────┐
              │    Driving Ports      │
              │    (Input Ports)      │
              ├───────────────────────┤
              │                       │
              │    APPLICATION        │
              │       CORE            │
              │    (Domain Logic)     │
              │                       │
              ├───────────────────────┤
              │    Driven Ports       │
              │   (Output Ports)      │
              └────┬─────────────┬────┘
                   │             │
            ┌──────┴──────┬──────┴──────┐
            │             │             │
       ┌────▼────┐   ┌────▼────┐   ┌────▼────┐
       │Database │   │  Email  │   │ Payment │
       │ Adapter │   │ Adapter │   │ Adapter │
       └─────────┘   └─────────┘   └─────────┘
            │              │              │
            ▼              ▼              ▼
                  Driven Adapters (Secondary)
```

## Directory Structure

```
├── cmd/
│   └── ordersvc/
│       └── main.go                    # wiring: bind adapters to ports
│
└── internal/
    ├── core/                          # Application core
    │   ├── money/
    │   │   └── money.go               # value object
    │   ├── order/
    │   │   ├── order.go               # entity + Reconstruct
    │   │   └── product.go
    │   │
    │   └── app/                       # Use cases + ports
    │       ├── ports_driving.go       # input ports (CreateOrderPort, ...)
    │       ├── ports_driven.go        # output ports (OrderRepository, PaymentGateway, ...)
    │       ├── create_order.go        # CreateOrderService
    │       ├── get_order.go
    │       └── cancel_order.go
    │
    └── adapters/                      # All adapters
        ├── driving/                   # Primary adapters (input)
        │   ├── httpapi/
        │   │   └── order_handler.go
        │   ├── graphql/
        │   │   └── resolver.go
        │   ├── cli/
        │   │   └── order_cmd.go
        │   └── events/
        │       └── order_consumer.go
        │
        └── driven/                    # Secondary adapters (output)
            ├── postgres/
            │   └── order_repo.go
            ├── mongo/
            │   └── order_repo.go
            ├── stripe/
            │   └── gateway.go
            ├── notification/
            │   ├── email.go
            │   └── sms.go
            └── pubsub/
                └── publisher.go
```

## Implementation

### Driving Port (Input Port)

The driving port is the core's published contract — the boundary that primary
adapters call. Its command/result types are DTOs, never domain entities.

```go
// internal/core/app/ports_driving.go
package app

import "context"

// CreateOrderPort is a driving (input) port. Driving adapters (HTTP, CLI,
// events) depend on this interface, never on the concrete service.
type CreateOrderPort interface {
	Execute(ctx context.Context, cmd CreateOrderCommand) (OrderResult, error)
}

// CreateOrderCommand is the input DTO for the create-order use case.
type CreateOrderCommand struct {
	CustomerID      string
	Items           []CommandItem
	ShippingAddress Address
}

// CommandItem is one requested line item.
type CommandItem struct {
	ProductID string
	Quantity  int64
}

// Address is the shipping destination carried across the boundary.
type Address struct {
	Street  string
	City    string
	ZipCode string
	Country string
}

// OrderResult is the output DTO returned across the boundary.
type OrderResult struct {
	OrderID  string
	Total    int64
	Currency string
	Status   string
}
```

### Driven Port (Output Port)

Driven ports are declared in the core (the **consumer**) as small interfaces.
Secondary adapters implement them; the core never imports an adapter.

```go
// internal/core/app/ports_driven.go
package app

import (
	"context"

	"github.com/example/ordersvc/internal/core/order"
)

// OrderRepository is a driven (output) port for persistence.
type OrderRepository interface {
	Save(ctx context.Context, o *order.Order) error
	FindByID(ctx context.Context, id string) (*order.Order, error)
	FindByCustomerID(ctx context.Context, customerID string) ([]*order.Order, error)
	NextID() string
}

// ProductRepository loads products referenced by an order.
type ProductRepository interface {
	FindByID(ctx context.Context, id string) (*order.Product, error)
}

// ChargeStatus enumerates the outcome of a payment operation.
type ChargeStatus string

const (
	ChargeSucceeded ChargeStatus = "succeeded"
	ChargePending   ChargeStatus = "pending"
	ChargeFailed    ChargeStatus = "failed"
)

// PaymentGateway is a driven port for charging and refunding payments.
type PaymentGateway interface {
	Charge(ctx context.Context, params ChargeParams) (ChargeResult, error)
	Refund(ctx context.Context, chargeID string, amount int64) (RefundResult, error)
}

// ChargeParams describes a charge request (amount in minor units).
type ChargeParams struct {
	Amount      int64
	Currency    string
	CustomerID  string
	Description string
}

// ChargeResult is the gateway's response to a charge.
type ChargeResult struct {
	ChargeID string
	Status   ChargeStatus
	Amount   int64
}

// RefundResult is the gateway's response to a refund.
type RefundResult struct {
	RefundID string
	Status   ChargeStatus
	Amount   int64
}

// EventPublisher emits domain events to secondary adapters.
type EventPublisher interface {
	Publish(ctx context.Context, event Event) error
}

// Event is a domain event carried across the boundary.
type Event struct {
	Type    string
	Payload map[string]any
}
```

### Application Service (Use Case Implementation)

```go
// internal/core/app/create_order.go
package app

import (
	"context"
	"errors"
	"fmt"

	"github.com/example/ordersvc/internal/core/order"
)

// Sentinel errors surfaced by the use case.
var (
	ErrProductNotFound = errors.New("product not found")
	ErrPaymentFailed   = errors.New("payment failed")
)

// CreateOrderService satisfies the CreateOrderPort driving port using the
// driven ports it depends on. Dependencies arrive through the constructor.
type CreateOrderService struct {
	orders   OrderRepository
	products ProductRepository
	payments PaymentGateway
	events   EventPublisher
}

// Compile-time proof the service satisfies its driving port.
var _ CreateOrderPort = (*CreateOrderService)(nil)

// NewCreateOrderService wires the service with its driven ports.
func NewCreateOrderService(
	orders OrderRepository,
	products ProductRepository,
	payments PaymentGateway,
	events EventPublisher,
) *CreateOrderService {
	return &CreateOrderService{
		orders:   orders,
		products: products,
		payments: payments,
		events:   events,
	}
}

// Execute runs the create-order use case end to end.
func (s *CreateOrderService) Execute(ctx context.Context, cmd CreateOrderCommand) (OrderResult, error) {
	// 1. Fetch products and validate.
	items := make([]order.Item, 0, len(cmd.Items))
	for _, want := range cmd.Items {
		p, err := s.products.FindByID(ctx, want.ProductID)
		if err != nil {
			return OrderResult{}, fmt.Errorf("load product %s: %w", want.ProductID, err)
		}
		if p == nil {
			return OrderResult{}, fmt.Errorf("%s: %w", want.ProductID, ErrProductNotFound)
		}
		items = append(items, order.NewItem(p, want.Quantity))
	}

	// 2. Create the domain entity (DTO address maps to the domain value object).
	o, err := order.New(s.orders.NextID(), cmd.CustomerID, items, order.Address(cmd.ShippingAddress))
	if err != nil {
		return OrderResult{}, fmt.Errorf("create order: %w", err)
	}

	// 3. Process payment through the driven port.
	total := o.Total()
	charge, err := s.payments.Charge(ctx, ChargeParams{
		Amount:      total.Amount(),
		Currency:    total.Currency(),
		CustomerID:  cmd.CustomerID,
		Description: "Order " + o.ID,
	})
	if err != nil {
		return OrderResult{}, fmt.Errorf("charge payment: %w", err)
	}
	if charge.Status == ChargeFailed {
		return OrderResult{}, ErrPaymentFailed
	}
	o.MarkAsPaid(charge.ChargeID)

	// 4. Persist.
	if err := s.orders.Save(ctx, o); err != nil {
		return OrderResult{}, fmt.Errorf("save order: %w", err)
	}

	// 5. Publish events.
	event := Event{
		Type: "ORDER_CREATED",
		Payload: map[string]any{
			"orderId":    o.ID,
			"customerId": o.CustomerID,
			"total":      total.Amount(),
		},
	}
	if err := s.events.Publish(ctx, event); err != nil {
		return OrderResult{}, fmt.Errorf("publish order created: %w", err)
	}

	return OrderResult{
		OrderID:  o.ID,
		Total:    total.Amount(),
		Currency: total.Currency(),
		Status:   string(o.Status()),
	}, nil
}
```

### Driving Adapter (HTTP Handler)

```go
// internal/adapters/driving/httpapi/order_handler.go
package httpapi

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/example/ordersvc/internal/core/app"
	"github.com/go-chi/chi/v5"
)

// orderCreator is the driving port this adapter consumes. Declaring it here (in
// the consumer) keeps the adapter bound to a minimal interface, not a struct.
type orderCreator interface {
	Execute(ctx context.Context, cmd app.CreateOrderCommand) (app.OrderResult, error)
}

// OrderHandler is a primary (driving) adapter translating HTTP into port calls.
type OrderHandler struct {
	create orderCreator
}

// NewOrderHandler wires the adapter with its driving port.
func NewOrderHandler(create orderCreator) *OrderHandler {
	return &OrderHandler{create: create}
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
	Shipping struct {
		Street  string `json:"street"`
		City    string `json:"city"`
		ZipCode string `json:"zip_code"`
		Country string `json:"country"`
	} `json:"shipping"`
}

type orderResponse struct {
	OrderID string `json:"order_id"`
	Total   int64  `json:"total"`
	Status  string `json:"status"`
}

// Create maps the HTTP request to a port command and the result back to JSON.
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}

	cmd := app.CreateOrderCommand{
		CustomerID: req.CustomerID,
		ShippingAddress: app.Address{
			Street:  req.Shipping.Street,
			City:    req.Shipping.City,
			ZipCode: req.Shipping.ZipCode,
			Country: req.Shipping.Country,
		},
	}
	for _, it := range req.Items {
		cmd.Items = append(cmd.Items, app.CommandItem{
			ProductID: it.ProductID,
			Quantity:  it.Quantity,
		})
	}

	result, err := h.create.Execute(r.Context(), cmd)
	if err != nil {
		http.Error(w, "could not create order", http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(orderResponse{
		OrderID: result.OrderID,
		Total:   result.Total,
		Status:  result.Status,
	})
}

// Get is elided here; it decodes the id path param and calls a getOrder port.
func (h *OrderHandler) Get(w http.ResponseWriter, r *http.Request) {
	_ = chi.URLParam(r, "id")
	http.Error(w, "not implemented", http.StatusNotImplemented)
}
```

### Driven Adapter (Repository)

```go
// internal/adapters/driven/postgres/order_repo.go
package postgres

import (
	"context"
	"errors"
	"fmt"

	"github.com/example/ordersvc/internal/core/order"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// OrderRepo is a secondary (driven) adapter satisfying app.OrderRepository.
type OrderRepo struct {
	pool *pgxpool.Pool
}

// NewOrderRepo builds the adapter over a pgx pool.
func NewOrderRepo(pool *pgxpool.Pool) *OrderRepo {
	return &OrderRepo{pool: pool}
}

// Save upserts the order and its items in one transaction, using parameterized
// queries throughout — never string concatenation.
func (r *OrderRepo) Save(ctx context.Context, o *order.Order) error {
	total := o.Total()

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
		INSERT INTO order_items (order_id, product_id, quantity, price)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (order_id, product_id) DO NOTHING`
	for _, it := range o.Items() {
		if _, err := tx.Exec(ctx, insItem, o.ID, it.ProductID, it.Quantity, it.Price.Amount()); err != nil {
			return fmt.Errorf("insert item %s: %w", it.ProductID, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

// FindByID loads an order, or (nil, nil) when it does not exist.
func (r *OrderRepo) FindByID(ctx context.Context, id string) (*order.Order, error) {
	var customerID, status string
	err := r.pool.QueryRow(ctx,
		`SELECT customer_id, status FROM orders WHERE id = $1`, id).
		Scan(&customerID, &status)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, fmt.Errorf("find order %s: %w", id, err)
	}
	// Item loading and full aggregate rehydration omitted for brevity.
	return order.Reconstruct(id, customerID, nil, order.Status(status)), nil
}

// FindByCustomerID lists a customer's orders, newest first.
func (r *OrderRepo) FindByCustomerID(ctx context.Context, customerID string) ([]*order.Order, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, status FROM orders WHERE customer_id = $1 ORDER BY created_at DESC`, customerID)
	if err != nil {
		return nil, fmt.Errorf("query orders for %s: %w", customerID, err)
	}
	defer rows.Close()

	var orders []*order.Order
	for rows.Next() {
		var id, status string
		if err := rows.Scan(&id, &status); err != nil {
			return nil, fmt.Errorf("scan order: %w", err)
		}
		orders = append(orders, order.Reconstruct(id, customerID, nil, order.Status(status)))
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate orders: %w", err)
	}
	return orders, nil
}

// NextID returns a fresh identifier for a new aggregate.
func (r *OrderRepo) NextID() string {
	return uuid.NewString()
}
```

### Driven Adapter (Payment Gateway)

```go
// internal/adapters/driven/stripe/gateway.go
package stripe

import (
	"context"
	"fmt"

	"github.com/example/ordersvc/internal/core/app"
	"github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/client"
)

// Gateway is a driven adapter implementing app.PaymentGateway over Stripe. It
// holds its own client rather than mutating stripe's package-global key.
type Gateway struct {
	sc *client.API
}

// Compile-time proof the adapter satisfies the driven port.
var _ app.PaymentGateway = (*Gateway)(nil)

// NewGateway builds a Stripe-backed payment adapter from an API key.
func NewGateway(apiKey string) *Gateway {
	return &Gateway{sc: client.New(apiKey, nil)}
}

// Charge creates and confirms a payment intent, translating the SDK result into
// the port's ChargeResult. A gateway error maps to a failed status, not a panic.
func (g *Gateway) Charge(ctx context.Context, params app.ChargeParams) (app.ChargeResult, error) {
	in := &stripe.PaymentIntentParams{
		Amount:      stripe.Int64(params.Amount),
		Currency:    stripe.String(params.Currency),
		Customer:    stripe.String(params.CustomerID),
		Description: stripe.String(params.Description),
		Confirm:     stripe.Bool(true),
		AutomaticPaymentMethods: &stripe.PaymentIntentAutomaticPaymentMethodsParams{
			Enabled:        stripe.Bool(true),
			AllowRedirects: stripe.String("never"),
		},
	}
	in.Context = ctx

	pi, err := g.sc.PaymentIntents.New(in)
	if err != nil {
		return app.ChargeResult{Status: app.ChargeFailed, Amount: params.Amount}, nil
	}

	status := app.ChargePending
	if pi.Status == stripe.PaymentIntentStatusSucceeded {
		status = app.ChargeSucceeded
	}
	return app.ChargeResult{
		ChargeID: pi.ID,
		Status:   status,
		Amount:   params.Amount,
	}, nil
}

// Refund reverses a prior charge, in full when amount is zero.
func (g *Gateway) Refund(ctx context.Context, chargeID string, amount int64) (app.RefundResult, error) {
	in := &stripe.RefundParams{PaymentIntent: stripe.String(chargeID)}
	if amount > 0 {
		in.Amount = stripe.Int64(amount)
	}
	in.Context = ctx

	rf, err := g.sc.Refunds.New(in)
	if err != nil {
		return app.RefundResult{}, fmt.Errorf("stripe refund: %w", err)
	}

	status := app.ChargeFailed
	if rf.Status == stripe.RefundStatusSucceeded {
		status = app.ChargeSucceeded
	}
	return app.RefundResult{
		RefundID: rf.ID,
		Status:   status,
		Amount:   rf.Amount,
	}, nil
}
```

## Wiring It Together

```go
// cmd/ordersvc/main.go
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/example/ordersvc/internal/adapters/driven/postgres"
	"github.com/example/ordersvc/internal/adapters/driven/pubsub"
	"github.com/example/ordersvc/internal/adapters/driven/stripe"
	"github.com/example/ordersvc/internal/adapters/driving/httpapi"
	"github.com/example/ordersvc/internal/core/app"
	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

// run binds driven adapters to the core, then exposes the core through a
// driving adapter. Ports are interfaces; the concrete adapters are chosen here.
func run() error {
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	defer pool.Close()

	// Driven (secondary) adapters.
	orders := postgres.NewOrderRepo(pool)
	products := postgres.NewProductRepo(pool)
	payments := stripe.NewGateway(os.Getenv("STRIPE_KEY"))
	events := pubsub.NewPublisher()

	// Core use case: depends only on driven ports, satisfies a driving port.
	var createOrder app.CreateOrderPort = app.NewCreateOrderService(orders, products, payments, events)

	// Driving (primary) adapter.
	handler := httpapi.NewOrderHandler(createOrder)

	r := chi.NewRouter()
	handler.Routes(r)

	log.Println("listening on :8080")
	return http.ListenAndServe(":8080", r)
}
```

## Key Differences from Clean Architecture

| Aspect | Clean Architecture | Hexagonal |
|--------|-------------------|-----------|
| Focus | Layers | Ports & Adapters |
| Terminology | Use Cases | Driving/Driven Ports |
| Structure | Concentric circles | Hexagon with adapters |
| Emphasis | Dependency direction | System boundaries |

## Benefits

| Benefit | Description |
|---------|-------------|
| Testability | Core can be tested without adapters |
| Flexibility | Swap adapters without changing core |
| Clarity | Clear system boundaries |
| Independence | Framework/infrastructure agnostic |
