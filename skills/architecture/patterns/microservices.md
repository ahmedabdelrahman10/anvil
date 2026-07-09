---
name: microservices
description: Microservices architecture patterns and best practices
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Microservices Architecture

## Overview

Microservices architecture structures an application as a collection of
loosely coupled, independently deployable services organized around
business capabilities.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        API Gateway                                │
│              (Routing, Auth, Rate Limiting)                       │
└─────────────┬──────────────┬──────────────┬─────────────────────┘
              │              │              │
    ┌─────────▼──────┐ ┌─────▼──────┐ ┌────▼───────┐
    │ User Service   │ │Order Service│ │Product Svc │
    │                │ │             │ │            │
    │  ┌──────────┐  │ │ ┌────────┐ │ │ ┌────────┐ │
    │  │ User DB  │  │ │ │Order DB│ │ │ │Prod DB │ │
    │  └──────────┘  │ │ └────────┘ │ │ └────────┘ │
    └───────┬────────┘ └─────┬──────┘ └──────┬─────┘
            │                │               │
            └────────────────┼───────────────┘
                             │
              ┌──────────────▼──────────────┐
              │       Message Broker         │
              │   (Events, Async Comm)       │
              └──────────────────────────────┘
```

## Service Design

### Service Structure

```
services/
├── user-service/
│   ├── cmd/
│   │   └── server/
│   │       └── main.go
│   ├── internal/
│   │   ├── user/                 # domain: entities + events
│   │   ├── command/              # write use-cases
│   │   ├── query/                # read use-cases
│   │   ├── postgres/             # persistence adapter
│   │   ├── messaging/            # event publish/subscribe
│   │   └── transport/
│   │       ├── http/
│   │       └── grpc/
│   ├── Dockerfile
│   └── go.mod
│
├── order-service/
├── product-service/
├── payment-service/
└── notification-service/
```

### Service Implementation

```go
// file: order-service/internal/order/create_order.go
package order

import (
	"context"
	"fmt"
)

// ProductClient is the small port this handler needs from the product service.
type ProductClient interface {
	Products(ctx context.Context, ids []string) ([]Product, error)
}

// EventPublisher publishes integration events to other services.
type EventPublisher interface {
	Publish(ctx context.Context, event DomainEvent) error
}

type CreateOrderHandler struct {
	orders    OrderRepository
	products  ProductClient
	publisher EventPublisher
}

func NewCreateOrderHandler(orders OrderRepository, products ProductClient, publisher EventPublisher) *CreateOrderHandler {
	return &CreateOrderHandler{orders: orders, products: products, publisher: publisher}
}

func (h *CreateOrderHandler) Handle(ctx context.Context, cmd CreateOrderCommand) (Result, error) {
	// 1. Validate products exist via a synchronous call.
	products, err := h.products.Products(ctx, cmd.ProductIDs())
	if err != nil {
		return Result{}, fmt.Errorf("fetch products: %w", err)
	}
	byID := make(map[string]Product, len(products))
	for _, p := range products {
		byID[p.ID] = p
	}

	// 2. Build the order.
	items := make([]OrderItem, 0, len(cmd.Items))
	for _, line := range cmd.Items {
		product, ok := byID[line.ProductID]
		if !ok {
			return Result{}, fmt.Errorf("unknown product %s", line.ProductID)
		}
		item, err := NewOrderItem(product, line.Quantity)
		if err != nil {
			return Result{}, fmt.Errorf("build order item: %w", err)
		}
		items = append(items, item)
	}

	order, err := NewOrder(cmd.CustomerID, items)
	if err != nil {
		return Result{}, fmt.Errorf("create order: %w", err)
	}

	// 3. Save locally.
	if err := h.orders.Save(ctx, order); err != nil {
		return Result{}, fmt.Errorf("save order: %w", err)
	}

	// 4. Publish an event for other services.
	if err := h.publisher.Publish(ctx, OrderCreated{
		OrderID:    order.ID(),
		CustomerID: order.CustomerID(),
		Items:      order.Items(),
		Total:      order.Total(),
	}); err != nil {
		return Result{}, fmt.Errorf("publish order created: %w", err)
	}

	return Result{OrderID: order.ID()}, nil
}

type Result struct {
	OrderID string
}
```

## Communication Patterns

### Synchronous (REST/gRPC)

```go
// file: order-service/internal/order/product_client.go
package order

import (
	"context"
	"fmt"

	productv1 "example.com/shop/gen/product/v1"
)

// breaker guards a downstream call; the small port is declared in the consumer.
type breaker interface {
	Execute(ctx context.Context, op func(context.Context) error) error
}

// ProductServiceClient wraps the generated gRPC stub with resilience.
type ProductServiceClient struct {
	grpc    productv1.ProductServiceClient
	breaker breaker
}

func NewProductServiceClient(grpc productv1.ProductServiceClient, breaker breaker) *ProductServiceClient {
	return &ProductServiceClient{grpc: grpc, breaker: breaker}
}

func (c *ProductServiceClient) Product(ctx context.Context, productID string) (Product, error) {
	var product Product
	err := c.breaker.Execute(ctx, func(ctx context.Context) error {
		resp, err := c.grpc.GetProduct(ctx, &productv1.GetProductRequest{ProductId: productID})
		if err != nil {
			return fmt.Errorf("get product %s: %w", productID, err)
		}
		product = Product{ID: resp.GetId(), Name: resp.GetName(), Price: resp.GetPrice(), Stock: int(resp.GetStock())}
		return nil
	})
	if err != nil {
		return Product{}, err
	}
	return product, nil
}

func (c *ProductServiceClient) CheckStock(ctx context.Context, productID string, quantity int32) (bool, error) {
	var available bool
	err := c.breaker.Execute(ctx, func(ctx context.Context) error {
		resp, err := c.grpc.CheckStock(ctx, &productv1.CheckStockRequest{ProductId: productID, Quantity: quantity})
		if err != nil {
			return fmt.Errorf("check stock %s: %w", productID, err)
		}
		available = resp.GetAvailable()
		return nil
	})
	if err != nil {
		return false, err
	}
	return available, nil
}
```

The contract itself lives in a proto file and is code-generated into the
`productv1` package:

```protobuf
// file: gen/product/v1/product.proto
syntax = "proto3";
package product.v1;

option go_package = "example.com/shop/gen/product/v1;productv1";

service ProductService {
  rpc GetProduct(GetProductRequest) returns (Product);
  rpc CheckStock(CheckStockRequest) returns (StockResponse);
}

message GetProductRequest {
  string product_id = 1;
}

message Product {
  string id = 1;
  string name = 2;
  double price = 3;
  int32 stock = 4;
}

message CheckStockRequest {
  string product_id = 1;
  int32 quantity = 2;
}

message StockResponse {
  bool available = 1;
}
```

### Asynchronous (Events/Messages)

```go
// file: order-service/internal/messaging/publisher.go
package messaging

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	amqp "github.com/rabbitmq/amqp091-go"
)

const domainEventsExchange = "domain_events"

// DomainEvent is the small interface the publisher needs.
type DomainEvent interface {
	EventType() string
}

// RabbitMQPublisher publishes domain events to a topic exchange.
type RabbitMQPublisher struct {
	channel *amqp.Channel
}

func NewRabbitMQPublisher(channel *amqp.Channel) *RabbitMQPublisher {
	return &RabbitMQPublisher{channel: channel}
}

func (p *RabbitMQPublisher) Publish(ctx context.Context, event DomainEvent) error {
	body, err := json.Marshal(envelope{
		EventID:    uuid.NewString(),
		EventType:  event.EventType(),
		OccurredAt: time.Now().UTC(),
		Payload:    event,
	})
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	if err := p.channel.PublishWithContext(ctx,
		domainEventsExchange, event.EventType(), false, false,
		amqp.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp.Persistent,
			Body:         body,
		}); err != nil {
		return fmt.Errorf("publish %s: %w", event.EventType(), err)
	}
	return nil
}

type envelope struct {
	EventID    string      `json:"eventId"`
	EventType  string      `json:"eventType"`
	OccurredAt time.Time   `json:"occurredAt"`
	Payload    DomainEvent `json:"payload"`
}

// file: notification-service/internal/messaging/order_consumer.go
package messaging

import (
	"context"
	"encoding/json"
	"fmt"

	amqp "github.com/rabbitmq/amqp091-go"
)

// NotificationService is the small port the consumer drives.
type NotificationService interface {
	SendOrderConfirmation(ctx context.Context, customerID, orderID string) error
	SendShippingNotification(ctx context.Context, customerID, trackingNumber string) error
}

type OrderCreatedPayload struct {
	OrderID    string `json:"orderId"`
	CustomerID string `json:"customerId"`
}

type OrderShippedPayload struct {
	CustomerID     string `json:"customerId"`
	TrackingNumber string `json:"trackingNumber"`
}

type OrderEventsConsumer struct {
	notifications NotificationService
}

func NewOrderEventsConsumer(notifications NotificationService) *OrderEventsConsumer {
	return &OrderEventsConsumer{notifications: notifications}
}

// Consume dispatches deliveries by routing key until the context is cancelled.
func (c *OrderEventsConsumer) Consume(ctx context.Context, deliveries <-chan amqp.Delivery) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case d, ok := <-deliveries:
			if !ok {
				return nil
			}
			if err := c.dispatch(ctx, d); err != nil {
				_ = d.Nack(false, true) // requeue on failure
				continue
			}
			_ = d.Ack(false)
		}
	}
}

func (c *OrderEventsConsumer) dispatch(ctx context.Context, d amqp.Delivery) error {
	switch d.RoutingKey {
	case "order.created":
		var e OrderCreatedPayload
		if err := json.Unmarshal(d.Body, &e); err != nil {
			return fmt.Errorf("decode order.created: %w", err)
		}
		return c.notifications.SendOrderConfirmation(ctx, e.CustomerID, e.OrderID)
	case "order.shipped":
		var e OrderShippedPayload
		if err := json.Unmarshal(d.Body, &e); err != nil {
			return fmt.Errorf("decode order.shipped: %w", err)
		}
		return c.notifications.SendShippingNotification(ctx, e.CustomerID, e.TrackingNumber)
	default:
		return nil // ignore unrelated events
	}
}
```

## Saga Pattern (Distributed Transactions)

```go
// file: order-service/internal/saga/create_order_saga.go
package saga

import (
	"context"
	"fmt"
	"log/slog"
)

// Choreography-based saga: order-service publishes events, other services react.
//
//	OrderCreated      → PaymentService charges     → PaymentCompleted
//	PaymentCompleted  → InventoryService reserves   → InventoryReserved
//	InventoryReserved → OrderService confirms        → OrderConfirmed
//
// Compensation on failure:
//
//	PaymentFailed   → OrderService cancels    → OrderCancelled
//	InventoryFailed → PaymentService refunds  → PaymentRefunded

// Ports the orchestrator drives (declared here in the consumer).
type (
	InventoryClient interface {
		Reserve(ctx context.Context, items []Item) (Reservation, error)
		CancelReservation(ctx context.Context, reservationID string) error
	}
	PaymentClient interface {
		Charge(ctx context.Context, customerID string, amount int64) (Charge, error)
		Refund(ctx context.Context, paymentID string) error
	}
	OrderRepository interface {
		Confirm(ctx context.Context, orderID string) error
		Cancel(ctx context.Context, orderID string) error
	}
)

type (
	Item        struct{ ProductID string }
	Reservation struct{ ID string }
	Charge      struct{ ID string }
)

type CreateOrderCommand struct {
	OrderID    string
	CustomerID string
	Items      []Item
	Total      int64
}

// State carries data across saga steps.
type State struct {
	OrderID       string
	CustomerID    string
	Items         []Item
	Total         int64
	ReservationID string
	PaymentID     string
}

// Step is one unit of an orchestrated saga plus its compensating action.
type Step struct {
	Name       string
	Execute    func(ctx context.Context, s *State) error
	Compensate func(ctx context.Context, s *State) error
}

type CreateOrderSaga struct {
	steps []Step
	log   *slog.Logger
}

func NewCreateOrderSaga(inventory InventoryClient, payments PaymentClient, orders OrderRepository, log *slog.Logger) *CreateOrderSaga {
	return &CreateOrderSaga{
		log: log,
		steps: []Step{
			{
				Name: "reserve_inventory",
				Execute: func(ctx context.Context, s *State) error {
					res, err := inventory.Reserve(ctx, s.Items)
					if err != nil {
						return err
					}
					s.ReservationID = res.ID
					return nil
				},
				Compensate: func(ctx context.Context, s *State) error {
					return inventory.CancelReservation(ctx, s.ReservationID)
				},
			},
			{
				Name: "process_payment",
				Execute: func(ctx context.Context, s *State) error {
					charge, err := payments.Charge(ctx, s.CustomerID, s.Total)
					if err != nil {
						return err
					}
					s.PaymentID = charge.ID
					return nil
				},
				Compensate: func(ctx context.Context, s *State) error {
					return payments.Refund(ctx, s.PaymentID)
				},
			},
			{
				Name: "confirm_order",
				Execute: func(ctx context.Context, s *State) error {
					return orders.Confirm(ctx, s.OrderID)
				},
				Compensate: func(ctx context.Context, s *State) error {
					return orders.Cancel(ctx, s.OrderID)
				},
			},
		},
	}
}

// Execute runs each step; on failure it compensates completed steps in reverse.
func (s *CreateOrderSaga) Execute(ctx context.Context, cmd CreateOrderCommand) (*State, error) {
	state := &State{
		OrderID:    cmd.OrderID,
		CustomerID: cmd.CustomerID,
		Items:      cmd.Items,
		Total:      cmd.Total,
	}

	var completed []Step
	for _, step := range s.steps {
		if err := step.Execute(ctx, state); err != nil {
			s.compensate(ctx, completed, state)
			return nil, fmt.Errorf("saga step %q failed: %w", step.Name, err)
		}
		completed = append(completed, step)
	}
	return state, nil
}

func (s *CreateOrderSaga) compensate(ctx context.Context, completed []Step, state *State) {
	// Compensate in reverse order; compensation is best-effort.
	for i := len(completed) - 1; i >= 0; i-- {
		step := completed[i]
		if err := step.Compensate(ctx, state); err != nil {
			s.log.Error("compensation failed", slog.String("step", step.Name), slog.Any("error", err))
		}
	}
}
```

## API Gateway

```go
// file: cmd/gateway/main.go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/httprate"
)

// route maps a path prefix to an upstream service and its middleware.
type route struct {
	pattern     string
	target      string
	middlewares []func(http.Handler) http.Handler
}

func newRouter(auth, rateLimit func(http.Handler) http.Handler) *chi.Mux {
	routes := []route{
		{pattern: "/api/users/*", target: "http://user-service", middlewares: []func(http.Handler) http.Handler{auth, rateLimit}},
		{pattern: "/api/orders/*", target: "http://order-service", middlewares: []func(http.Handler) http.Handler{auth, rateLimit}},
		{pattern: "/api/products/*", target: "http://product-service", middlewares: []func(http.Handler) http.Handler{rateLimit}}, // public access
	}

	r := chi.NewRouter()
	for _, rt := range routes {
		r.With(rt.middlewares...).Handle(rt.pattern, reverseProxy(rt.target))
	}
	return r
}

func reverseProxy(target string) http.Handler {
	u, err := url.Parse(target)
	if err != nil {
		panic(fmt.Sprintf("invalid upstream %q: %v", target, err))
	}
	return httputil.NewSingleHostReverseProxy(u)
}

type contextKey string

const userContextKey contextKey = "user"

// User is the authenticated principal carried on the request context.
type User struct {
	ID string
}

// TokenVerifier is the small port the auth middleware needs.
type TokenVerifier interface {
	Verify(ctx context.Context, token string) (User, error)
}

func authMiddleware(verifier TokenVerifier) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := bearerToken(r)
			if token == "" {
				writeError(w, http.StatusUnauthorized, "Unauthorized")
				return
			}

			user, err := verifier.Verify(r.Context(), token)
			if err != nil {
				writeError(w, http.StatusUnauthorized, "Invalid token")
				return
			}

			ctx := context.WithValue(r.Context(), userContextKey, user)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimPrefix(header, prefix)
}

// rateLimitMiddleware allows 100 requests per minute, keyed by user or IP.
func rateLimitMiddleware() func(http.Handler) http.Handler {
	return httprate.Limit(100, time.Minute, httprate.WithKeyFuncs(func(r *http.Request) (string, error) {
		if user, ok := r.Context().Value(userContextKey).(User); ok {
			return user.ID, nil
		}
		return httprate.KeyByIP(r)
	}))
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
```

## Service Discovery

```go
// file: internal/discovery/consul.go
package discovery

import (
	"context"
	"fmt"

	consul "github.com/hashicorp/consul/api"
)

// ServiceInfo describes a service instance to register.
type ServiceInfo struct {
	Name       string
	InstanceID string
	Host       string
	Port       int
}

// ServiceInstance is a discovered, healthy instance.
type ServiceInstance struct {
	ID   string
	Host string
	Port int
}

// ConsulDiscovery registers and discovers services via Consul.
type ConsulDiscovery struct {
	client *consul.Client
}

func NewConsulDiscovery(client *consul.Client) *ConsulDiscovery {
	return &ConsulDiscovery{client: client}
}

func (d *ConsulDiscovery) Register(ctx context.Context, svc ServiceInfo) error {
	reg := &consul.AgentServiceRegistration{
		ID:      svc.InstanceID,
		Name:    svc.Name,
		Address: svc.Host,
		Port:    svc.Port,
		Check: &consul.AgentServiceCheck{
			HTTP:     fmt.Sprintf("http://%s:%d/health", svc.Host, svc.Port),
			Interval: "10s",
			Timeout:  "5s",
		},
	}
	if err := d.client.Agent().ServiceRegisterOpts(reg, consul.ServiceRegisterOpts{}.WithContext(ctx)); err != nil {
		return fmt.Errorf("register service %s: %w", svc.Name, err)
	}
	return nil
}

func (d *ConsulDiscovery) Discover(ctx context.Context, serviceName string) ([]ServiceInstance, error) {
	// Only passing (healthy) instances.
	entries, _, err := d.client.Health().Service(serviceName, "", true, (&consul.QueryOptions{}).WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("discover service %s: %w", serviceName, err)
	}

	instances := make([]ServiceInstance, 0, len(entries))
	for _, entry := range entries {
		instances = append(instances, ServiceInstance{
			ID:   entry.Service.ID,
			Host: entry.Service.Address,
			Port: entry.Service.Port,
		})
	}
	return instances, nil
}

func (d *ConsulDiscovery) Deregister(ctx context.Context, instanceID string) error {
	if err := d.client.Agent().ServiceDeregisterOpts(instanceID, (&consul.QueryOptions{}).WithContext(ctx)); err != nil {
		return fmt.Errorf("deregister %s: %w", instanceID, err)
	}
	return nil
}
```

## Circuit Breaker Pattern

```go
// file: internal/resilience/circuit_breaker.go
package resilience

import (
	"context"
	"errors"
	"sync"
	"time"
)

type state int

const (
	stateClosed state = iota
	stateOpen
	stateHalfOpen
)

// ErrCircuitOpen is returned when the breaker is open and rejecting calls.
var ErrCircuitOpen = errors.New("circuit breaker is open")

// Options configures a CircuitBreaker.
type Options struct {
	FailureThreshold int
	ResetTimeout     time.Duration
}

// CircuitBreaker guards an operation, failing fast once errors pile up.
type CircuitBreaker struct {
	opts Options

	mu          sync.Mutex
	state       state
	failures    int
	lastFailure time.Time
}

func NewCircuitBreaker(opts Options) *CircuitBreaker {
	return &CircuitBreaker{opts: opts, state: stateClosed}
}

func (b *CircuitBreaker) Execute(ctx context.Context, op func(context.Context) error) error {
	if !b.allow() {
		return ErrCircuitOpen
	}

	if err := op(ctx); err != nil {
		b.onFailure()
		return err
	}
	b.onSuccess()
	return nil
}

func (b *CircuitBreaker) allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.state == stateOpen {
		if time.Since(b.lastFailure) < b.opts.ResetTimeout {
			return false
		}
		b.state = stateHalfOpen
	}
	return true
}

func (b *CircuitBreaker) onSuccess() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.failures = 0
	b.state = stateClosed
}

func (b *CircuitBreaker) onFailure() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.failures++
	b.lastFailure = time.Now()
	if b.failures >= b.opts.FailureThreshold {
		b.state = stateOpen
	}
}
```

```go
// file: internal/app/product_lookup.go
package app

import (
	"context"
	"time"

	"example.com/shop/internal/order"
	"example.com/shop/internal/resilience"
)

// Wire a long-lived breaker once (e.g. at startup) and guard each call with it.
func newProductBreaker() *resilience.CircuitBreaker {
	return resilience.NewCircuitBreaker(resilience.Options{
		FailureThreshold: 5,
		ResetTimeout:     30 * time.Second,
	})
}

func lookupProduct(ctx context.Context, breaker *resilience.CircuitBreaker, client *order.ProductServiceClient, productID string) (order.Product, error) {
	var product order.Product
	err := breaker.Execute(ctx, func(ctx context.Context) error {
		p, err := client.Product(ctx, productID)
		if err != nil {
			return err
		}
		product = p
		return nil
	})
	if err != nil {
		return order.Product{}, err
	}
	return product, nil
}
```

## Distributed Tracing

```go
// file: internal/tracing/tracing.go
package tracing

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
)

// Traced runs op inside a span named spanName, recording any error on the span.
// A generic helper replaces the decorator idiom: wrap the call, don't annotate it.
func Traced[T any](ctx context.Context, spanName string, op func(context.Context) (T, error)) (T, error) {
	ctx, span := otel.Tracer("order-service").Start(ctx, spanName)
	defer span.End()

	result, err := op(ctx)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return result, fmt.Errorf("%s: %w", spanName, err)
	}
	span.SetStatus(codes.Ok, "")
	return result, nil
}
```

```go
// file: internal/app/order_service.go
package app

import (
	"context"

	"example.com/shop/internal/order"
	"example.com/shop/internal/tracing"
)

type OrderService struct {
	handler *order.CreateOrderHandler
}

// CreateOrder wraps the whole operation in a span, propagating ctx throughout.
func (s *OrderService) CreateOrder(ctx context.Context, cmd order.CreateOrderCommand) (order.Result, error) {
	return tracing.Traced(ctx, "CreateOrder", func(ctx context.Context) (order.Result, error) {
		return s.handler.Handle(ctx, cmd)
	})
}
```

## Data Patterns

### Database per Service

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  User Service   │  │  Order Service  │  │ Product Service │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                    │
    ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
    │ User DB │          │Order DB │          │Prod DB  │
    │(Postgres)│          │(MongoDB)│          │(Postgres)│
    └─────────┘          └─────────┘          └─────────┘
```

### API Composition

```go
// file: cmd/gateway/order_details.go
package main

import (
	"context"
	"fmt"

	"golang.org/x/sync/errgroup"
)

// The composer depends on small read-only ports from each service.
type (
	orderReader interface {
		Order(ctx context.Context, orderID string) (OrderView, error)
	}
	userReader interface {
		User(ctx context.Context, userID string) (UserView, error)
	}
	productReader interface {
		Products(ctx context.Context, ids []string) ([]ProductView, error)
	}
)

type OrderDetailsComposer struct {
	orders   orderReader
	users    userReader
	products productReader
}

func NewOrderDetailsComposer(orders orderReader, users userReader, products productReader) *OrderDetailsComposer {
	return &OrderDetailsComposer{orders: orders, users: users, products: products}
}

func (c *OrderDetailsComposer) OrderDetails(ctx context.Context, orderID string) (OrderDetailsView, error) {
	order, err := c.orders.Order(ctx, orderID)
	if err != nil {
		return OrderDetailsView{}, fmt.Errorf("fetch order %s: %w", orderID, err)
	}

	// Fetch customer and products in parallel.
	var (
		customer UserView
		products []ProductView
	)
	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		u, err := c.users.User(ctx, order.CustomerID)
		if err != nil {
			return fmt.Errorf("fetch customer %s: %w", order.CustomerID, err)
		}
		customer = u
		return nil
	})
	g.Go(func() error {
		p, err := c.products.Products(ctx, order.ProductIDs())
		if err != nil {
			return fmt.Errorf("fetch products: %w", err)
		}
		products = p
		return nil
	})
	if err := g.Wait(); err != nil {
		return OrderDetailsView{}, err
	}

	byID := make(map[string]ProductView, len(products))
	for _, p := range products {
		byID[p.ID] = p
	}

	items := make([]OrderItemView, len(order.Items))
	for i, item := range order.Items {
		items[i] = OrderItemView{
			ProductID:   item.ProductID,
			ProductName: byID[item.ProductID].Name,
			Quantity:    item.Quantity,
			UnitPrice:   item.Price,
		}
	}

	return OrderDetailsView{
		OrderID:   order.ID,
		Status:    order.Status,
		Customer:  CustomerView{ID: customer.ID, Name: customer.Name, Email: customer.Email},
		Items:     items,
		Total:     order.Total,
		CreatedAt: order.CreatedAt,
	}, nil
}
```

## When to Use Microservices

### Good Fit
- Large, complex domains
- Multiple teams working independently
- Different scaling requirements per component
- Polyglot persistence needs
- Frequent deployments needed

### When NOT to Use
- Small teams / small applications
- Unclear domain boundaries
- Tight latency requirements
- Limited DevOps capabilities
- Early-stage startups (usually)
```
