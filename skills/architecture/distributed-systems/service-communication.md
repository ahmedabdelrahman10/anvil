---
name: service-communication
description: Patterns for inter-service communication in distributed systems
category: architecture/distributed-systems
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Service Communication Patterns

## Overview

Service communication defines how services interact in distributed systems.
Choosing the right communication pattern impacts reliability, performance,
and system complexity.

## Communication Styles

### Synchronous vs Asynchronous

```
┌─────────────────────────────────────────────────────────────┐
│                    SYNCHRONOUS                               │
│  ┌────────┐    Request    ┌────────┐                        │
│  │Service │ ────────────► │Service │                        │
│  │   A    │ ◄──────────── │   B    │                        │
│  └────────┘    Response   └────────┘                        │
│         Caller blocks until response                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   ASYNCHRONOUS                               │
│  ┌────────┐    Message    ┌────────┐    Message  ┌────────┐ │
│  │Service │ ────────────► │ Queue  │ ──────────► │Service │ │
│  │   A    │               │        │             │   B    │ │
│  └────────┘               └────────┘             └────────┘ │
│         Caller continues immediately                        │
└─────────────────────────────────────────────────────────────┘
```

## REST API Communication

```go
package communication

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"time"
)

// HTTPClientConfig configures a resilient service client.
type HTTPClientConfig struct {
	BaseURL        string
	Timeout        time.Duration
	Retries        int
	CircuitBreaker CircuitBreakerConfig
}

// ServiceClient calls a downstream HTTP service with retry and circuit breaking.
type ServiceClient struct {
	cfg     HTTPClientConfig
	http    *http.Client
	breaker *CircuitBreaker
}

// NewServiceClient wires a client with a bounded HTTP timeout and a breaker.
func NewServiceClient(cfg HTTPClientConfig) *ServiceClient {
	return &ServiceClient{
		cfg:     cfg,
		http:    &http.Client{Timeout: cfg.Timeout},
		breaker: NewCircuitBreaker(cfg.CircuitBreaker),
	}
}

// Get fetches path and decodes the JSON response body into out.
func (c *ServiceClient) Get(ctx context.Context, path string, out any) error {
	return c.breaker.Execute(ctx, func(ctx context.Context) error {
		return c.withRetry(ctx, func(ctx context.Context) error {
			return c.do(ctx, http.MethodGet, path, nil, out)
		})
	})
}

// Post sends body as JSON to path and decodes the JSON response into out.
func (c *ServiceClient) Post(ctx context.Context, path string, body, out any) error {
	return c.breaker.Execute(ctx, func(ctx context.Context) error {
		return c.withRetry(ctx, func(ctx context.Context) error {
			return c.do(ctx, http.MethodPost, path, body, out)
		})
	})
}

func (c *ServiceClient) do(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request: %w", err)
		}
		reader = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.cfg.BaseURL+path, reader)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= http.StatusBadRequest {
		return &StatusError{StatusCode: resp.StatusCode}
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func (c *ServiceClient) withRetry(ctx context.Context, fn func(context.Context) error) error {
	var lastErr error

	for attempt := 0; attempt < c.cfg.Retries; attempt++ {
		lastErr = fn(ctx)
		if lastErr == nil {
			return nil
		}
		if !isRetryable(lastErr) {
			return lastErr
		}

		select {
		case <-time.After(backoff(attempt)):
		case <-ctx.Done():
			return fmt.Errorf("retry aborted: %w", ctx.Err())
		}
	}

	return fmt.Errorf("all %d attempts failed: %w", c.cfg.Retries, lastErr)
}

// StatusError carries a non-2xx status for retry classification.
type StatusError struct {
	StatusCode int
}

func (e *StatusError) Error() string { return fmt.Sprintf("unexpected status %d", e.StatusCode) }

func isRetryable(err error) bool {
	var statusErr *StatusError
	if !errors.As(err, &statusErr) {
		return false
	}
	switch statusErr.StatusCode {
	case 408, 429, 500, 502, 503, 504:
		return true
	default:
		return false
	}
}

func backoff(attempt int) time.Duration {
	d := time.Duration(math.Pow(2, float64(attempt))) * time.Second
	if d > 30*time.Second {
		return 30 * time.Second
	}
	return d
}

// Usage
func fetchUser(ctx context.Context, userID string) (User, error) {
	userService := NewServiceClient(HTTPClientConfig{
		BaseURL:        "http://user-service:3000",
		Timeout:        5 * time.Second,
		Retries:        3,
		CircuitBreaker: CircuitBreakerConfig{FailureThreshold: 5, Timeout: 30 * time.Second},
	})

	var user User
	if err := userService.Get(ctx, "/users/"+userID, &user); err != nil {
		return User{}, fmt.Errorf("get user %s: %w", userID, err)
	}
	return user, nil
}
```

## gRPC Communication

```go
package communication

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	userpb "github.com/example/app/gen/user"
)

// Proto definition (user/user.proto):
//
//	syntax = "proto3";
//
//	service UserService {
//	  rpc GetUser(GetUserRequest) returns (User);
//	  rpc CreateUser(CreateUserRequest) returns (User);
//	  rpc ListUsers(ListUsersRequest) returns (stream User);
//	  rpc UpdateUsers(stream UpdateUserRequest) returns (UpdateResult);
//	}
//
//	message User {
//	  string id = 1;
//	  string email = 2;
//	  string name = 3;
//	}

// ErrUserNotFound is the sentinel the repository returns for a missing user.
var ErrUserNotFound = errors.New("user not found")

// UserRepository is the small interface the gRPC server depends on.
type UserRepository interface {
	FindByID(ctx context.Context, id string) (User, error)
	FindByCriteria(ctx context.Context, criteria string) ([]User, error)
}

// userServer implements the generated userpb.UserServiceServer.
type userServer struct {
	userpb.UnimplementedUserServiceServer
	repo UserRepository
}

// NewUserServer wires the gRPC server with its repository dependency.
func NewUserServer(repo UserRepository) *userServer {
	return &userServer{repo: repo}
}

// GetUser returns a single user, mapping a missing user to a NOT_FOUND status.
func (s *userServer) GetUser(ctx context.Context, req *userpb.GetUserRequest) (*userpb.User, error) {
	user, err := s.repo.FindByID(ctx, req.GetId())
	if errors.Is(err, ErrUserNotFound) {
		return nil, status.Errorf(codes.NotFound, "user %s not found", req.GetId())
	}
	if err != nil {
		return nil, status.Errorf(codes.Internal, "find user: %v", err)
	}
	return &userpb.User{Id: user.ID, Email: user.Email, Name: user.Name}, nil
}

// ListUsers streams the users matching the request criteria.
func (s *userServer) ListUsers(req *userpb.ListUsersRequest, stream userpb.UserService_ListUsersServer) error {
	users, err := s.repo.FindByCriteria(stream.Context(), req.GetCriteria())
	if err != nil {
		return status.Errorf(codes.Internal, "find by criteria: %v", err)
	}

	for _, user := range users {
		if err := stream.Send(&userpb.User{Id: user.ID, Email: user.Email, Name: user.Name}); err != nil {
			return fmt.Errorf("stream send: %w", err)
		}
	}
	return nil
}

// ServeUsers registers the service and blocks serving on addr.
func ServeUsers(repo UserRepository, addr string) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}

	srv := grpc.NewServer()
	userpb.RegisterUserServiceServer(srv, NewUserServer(repo))
	if err := srv.Serve(lis); err != nil {
		return fmt.Errorf("serve: %w", err)
	}
	return nil
}

// GRPCUserClient wraps a generated client with context-first helpers.
type GRPCUserClient struct {
	conn   *grpc.ClientConn
	client userpb.UserServiceClient
}

// NewGRPCUserClient dials address and returns a ready client.
func NewGRPCUserClient(address string) (*GRPCUserClient, error) {
	conn, err := grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", address, err)
	}
	return &GRPCUserClient{conn: conn, client: userpb.NewUserServiceClient(conn)}, nil
}

// Close releases the underlying connection.
func (c *GRPCUserClient) Close() error { return c.conn.Close() }

// GetUser calls the unary RPC. The caller's ctx carries the deadline and is
// propagated to the server for cancellation.
func (c *GRPCUserClient) GetUser(ctx context.Context, userID string) (*userpb.User, error) {
	user, err := c.client.GetUser(ctx, &userpb.GetUserRequest{Id: userID})
	if err != nil {
		return nil, fmt.Errorf("get user %s: %w", userID, err)
	}
	return user, nil
}

// ListUsers consumes the server stream and returns the collected users.
func (c *GRPCUserClient) ListUsers(ctx context.Context, criteria string) ([]*userpb.User, error) {
	stream, err := c.client.ListUsers(ctx, &userpb.ListUsersRequest{Criteria: criteria})
	if err != nil {
		return nil, fmt.Errorf("list users: %w", err)
	}

	var users []*userpb.User
	for {
		user, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return users, nil
		}
		if err != nil {
			return nil, fmt.Errorf("stream recv: %w", err)
		}
		users = append(users, user)
	}
}
```

## Message Queue Communication

```go
package communication

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/segmentio/kafka-go"
)

// Message is a broker-agnostic envelope.
type Message struct {
	ID       string
	Type     string
	Payload  json.RawMessage
	Metadata MessageMetadata
}

// MessageMetadata carries routing and provenance data.
type MessageMetadata struct {
	CorrelationID string
	Timestamp     time.Time
	Source        string
	Version       string
}

// MessageHandler processes a delivered message. Returning an error signals the
// broker to nack the message (and route it to a dead-letter queue).
type MessageHandler func(ctx context.Context, msg Message) error

// MessageBroker abstracts publish/subscribe over a concrete transport.
type MessageBroker interface {
	Publish(ctx context.Context, topic string, msg Message) error
	Subscribe(ctx context.Context, topic string, handler MessageHandler) error
}

// RabbitMQBroker publishes and consumes via an AMQP channel.
type RabbitMQBroker struct {
	ch *amqp.Channel
}

// NewRabbitMQBroker opens a channel on an established connection.
func NewRabbitMQBroker(conn *amqp.Connection) (*RabbitMQBroker, error) {
	ch, err := conn.Channel()
	if err != nil {
		return nil, fmt.Errorf("open channel: %w", err)
	}
	return &RabbitMQBroker{ch: ch}, nil
}

// Publish sends msg to a durable topic exchange, keyed by message type.
func (b *RabbitMQBroker) Publish(ctx context.Context, topic string, msg Message) error {
	if err := b.ch.ExchangeDeclare(topic, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange: %w", err)
	}

	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode message: %w", err)
	}

	err = b.ch.PublishWithContext(ctx, topic, msg.Type, false, false, amqp.Publishing{
		DeliveryMode:  amqp.Persistent,
		MessageId:     msg.ID,
		CorrelationId: msg.Metadata.CorrelationID,
		Timestamp:     msg.Metadata.Timestamp,
		ContentType:   "application/json",
		Body:          body,
		Headers: amqp.Table{
			"source":  msg.Metadata.Source,
			"version": msg.Metadata.Version,
		},
	})
	if err != nil {
		return fmt.Errorf("publish: %w", err)
	}
	return nil
}

// Subscribe binds an exclusive queue to the topic and dispatches deliveries to
// handler until ctx is cancelled. Failed deliveries are nacked without requeue
// so they land in the configured dead-letter queue.
func (b *RabbitMQBroker) Subscribe(ctx context.Context, topic string, handler MessageHandler) error {
	if err := b.ch.ExchangeDeclare(topic, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange: %w", err)
	}

	queue, err := b.ch.QueueDeclare("", false, true, true, false, nil)
	if err != nil {
		return fmt.Errorf("declare queue: %w", err)
	}
	if err := b.ch.QueueBind(queue.Name, "#", topic, false, nil); err != nil {
		return fmt.Errorf("bind queue: %w", err)
	}

	deliveries, err := b.ch.Consume(queue.Name, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume: %w", err)
	}

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case delivery, ok := <-deliveries:
				if !ok {
					return
				}
				var msg Message
				if err := json.Unmarshal(delivery.Body, &msg); err != nil {
					_ = delivery.Nack(false, false)
					continue
				}
				if err := handler(ctx, msg); err != nil {
					_ = delivery.Nack(false, false) // dead-letter
					continue
				}
				_ = delivery.Ack(false)
			}
		}
	}()
	return nil
}

// KafkaBroker publishes and consumes via kafka-go writers/readers.
type KafkaBroker struct {
	writer *kafka.Writer
	reader *kafka.Reader
}

// Publish writes msg to the topic, keyed by correlation ID for partitioning.
func (b *KafkaBroker) Publish(ctx context.Context, topic string, msg Message) error {
	value, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("encode message: %w", err)
	}

	err = b.writer.WriteMessages(ctx, kafka.Message{
		Topic: topic,
		Key:   []byte(msg.Metadata.CorrelationID),
		Value: value,
		Headers: []kafka.Header{
			{Key: "message-type", Value: []byte(msg.Type)},
			{Key: "source", Value: []byte(msg.Metadata.Source)},
			{Key: "version", Value: []byte(msg.Metadata.Version)},
		},
	})
	if err != nil {
		return fmt.Errorf("write message: %w", err)
	}
	return nil
}

// Subscribe reads from the topic and dispatches to handler until ctx ends.
func (b *KafkaBroker) Subscribe(ctx context.Context, topic string, handler MessageHandler) error {
	for {
		record, err := b.reader.ReadMessage(ctx)
		if errors.Is(err, context.Canceled) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read message: %w", err)
		}

		var msg Message
		if err := json.Unmarshal(record.Value, &msg); err != nil {
			return fmt.Errorf("decode message: %w", err)
		}
		if err := handler(ctx, msg); err != nil {
			return fmt.Errorf("handle message: %w", err)
		}
	}
}

// InventoryService is the small dependency the subscriber drives.
type InventoryService interface {
	ReserveItems(ctx context.Context, payload json.RawMessage) error
}

// Usage
func runOrders(ctx context.Context, broker MessageBroker, inventory InventoryService) error {
	payload, err := json.Marshal(map[string]any{"orderId": "123", "customerId": "456", "total": 99.99})
	if err != nil {
		return fmt.Errorf("encode payload: %w", err)
	}

	// Publisher
	err = broker.Publish(ctx, "orders", Message{
		ID:      uuid.NewString(),
		Type:    "order.created",
		Payload: payload,
		Metadata: MessageMetadata{
			CorrelationID: uuid.NewString(),
			Timestamp:     time.Now(),
			Source:        "order-service",
			Version:       "1.0",
		},
	})
	if err != nil {
		return fmt.Errorf("publish order: %w", err)
	}

	// Subscriber
	return broker.Subscribe(ctx, "orders", func(ctx context.Context, msg Message) error {
		if msg.Type != "order.created" {
			return nil
		}
		return inventory.ReserveItems(ctx, msg.Payload)
	})
}
```

## Event-Driven Communication

```go
package communication

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"
)

// DomainEvent is implemented by every domain event.
type DomainEvent interface {
	EventID() string
	EventType() string
	OccurredOn() time.Time
}

// BaseEvent provides the identity and timing fields events embed.
type BaseEvent struct {
	ID   string
	Type string
	At   time.Time
}

// NewBaseEvent stamps an event with an ID and timestamp.
func NewBaseEvent(eventType string) BaseEvent {
	return BaseEvent{ID: uuid.NewString(), Type: eventType, At: time.Now()}
}

func (e BaseEvent) EventID() string       { return e.ID }
func (e BaseEvent) EventType() string     { return e.Type }
func (e BaseEvent) OccurredOn() time.Time { return e.At }

// OrderItem is a single line item on an order.
type OrderItem struct {
	SKU      string
	Quantity int
}

// OrderPlacedEvent is emitted when a customer places an order.
type OrderPlacedEvent struct {
	BaseEvent
	OrderID    string
	CustomerID string
	Items      []OrderItem
	Total      float64
}

// NewOrderPlacedEvent constructs the event with its type pre-set.
func NewOrderPlacedEvent(orderID, customerID string, items []OrderItem, total float64) OrderPlacedEvent {
	return OrderPlacedEvent{
		BaseEvent:  NewBaseEvent("order.placed"),
		OrderID:    orderID,
		CustomerID: customerID,
		Items:      items,
		Total:      total,
	}
}

// EventHandler processes a decoded domain event.
type EventHandler func(ctx context.Context, event DomainEvent) error

// EventBus publishes domain events and routes them to handlers.
type EventBus interface {
	Publish(ctx context.Context, event DomainEvent) error
	Subscribe(ctx context.Context, eventType string, handler EventHandler) error
}

// DistributedEventBus bridges domain events onto a MessageBroker.
type DistributedEventBus struct {
	broker  MessageBroker
	service string
}

// NewDistributedEventBus wires the bus to a broker for the current service.
func NewDistributedEventBus(broker MessageBroker) *DistributedEventBus {
	return &DistributedEventBus{broker: broker, service: os.Getenv("SERVICE_NAME")}
}

// Publish serializes an event and publishes it on the domain-events topic.
func (b *DistributedEventBus) Publish(ctx context.Context, event DomainEvent) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("encode event: %w", err)
	}

	return b.broker.Publish(ctx, "domain-events", Message{
		ID:      event.EventID(),
		Type:    event.EventType(),
		Payload: payload,
		Metadata: MessageMetadata{
			CorrelationID: event.EventID(),
			Timestamp:     event.OccurredOn(),
			Source:        b.service,
			Version:       "1.0",
		},
	})
}

// Subscribe routes messages of eventType to handler as decoded events.
func (b *DistributedEventBus) Subscribe(ctx context.Context, eventType string, handler EventHandler) error {
	return b.broker.Subscribe(ctx, "domain-events", func(ctx context.Context, msg Message) error {
		if msg.Type != eventType {
			return nil
		}
		var event OrderPlacedEvent
		if err := json.Unmarshal(msg.Payload, &event); err != nil {
			return fmt.Errorf("decode event: %w", err)
		}
		return handler(ctx, event)
	})
}

// The dependencies each subscribing service drives.
type (
	InventoryService interface {
		ReserveItems(ctx context.Context, items []OrderItem) error
	}
	NotificationService interface {
		SendOrderConfirmation(ctx context.Context, customerID, orderID string) error
	}
	AnalyticsService interface {
		TrackOrder(ctx context.Context, event DomainEvent) error
	}
)

// registerHandlers wires the same event to handlers in different services.
func registerHandlers(ctx context.Context, bus EventBus, inventory InventoryService, notifications NotificationService, analytics AnalyticsService) error {
	// Inventory Service
	err := bus.Subscribe(ctx, "order.placed", func(ctx context.Context, event DomainEvent) error {
		placed, ok := event.(OrderPlacedEvent)
		if !ok {
			return nil
		}
		return inventory.ReserveItems(ctx, placed.Items)
	})
	if err != nil {
		return fmt.Errorf("subscribe inventory: %w", err)
	}

	// Notification Service
	err = bus.Subscribe(ctx, "order.placed", func(ctx context.Context, event DomainEvent) error {
		placed, ok := event.(OrderPlacedEvent)
		if !ok {
			return nil
		}
		return notifications.SendOrderConfirmation(ctx, placed.CustomerID, placed.OrderID)
	})
	if err != nil {
		return fmt.Errorf("subscribe notifications: %w", err)
	}

	// Analytics Service
	err = bus.Subscribe(ctx, "order.placed", func(ctx context.Context, event DomainEvent) error {
		return analytics.TrackOrder(ctx, event)
	})
	if err != nil {
		return fmt.Errorf("subscribe analytics: %w", err)
	}
	return nil
}
```

## Service Discovery

```go
package communication

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// ServiceInstance describes one registered instance of a service.
type ServiceInstance struct {
	ID             string
	Name           string
	Host           string
	Port           int
	Metadata       map[string]string
	HealthCheckURL string
}

// ServiceRegistry registers, discovers, and watches service instances.
type ServiceRegistry interface {
	Register(ctx context.Context, instance ServiceInstance) error
	Deregister(ctx context.Context, serviceID string) error
	Discover(ctx context.Context, serviceName string) ([]ServiceInstance, error)
	Watch(ctx context.Context, serviceName string, onChange func([]ServiceInstance)) error
}

// ConsulClient is the small slice of the Consul API the registry needs.
type ConsulClient interface {
	Register(ctx context.Context, reg ConsulRegistration) error
	HealthyInstances(ctx context.Context, serviceName string) ([]ServiceInstance, error)
}

// ConsulRegistration is the payload passed to Consul's agent API.
type ConsulRegistration struct {
	ID       string
	Name     string
	Address  string
	Port     int
	Meta     map[string]string
	CheckURL string
	Interval time.Duration
	Timeout  time.Duration
}

// ConsulServiceRegistry adapts a ConsulClient to the ServiceRegistry interface.
type ConsulServiceRegistry struct {
	consul ConsulClient
}

// NewConsulServiceRegistry wires the registry to a Consul client.
func NewConsulServiceRegistry(consul ConsulClient) *ConsulServiceRegistry {
	return &ConsulServiceRegistry{consul: consul}
}

// Register advertises an instance with an HTTP health check.
func (r *ConsulServiceRegistry) Register(ctx context.Context, instance ServiceInstance) error {
	err := r.consul.Register(ctx, ConsulRegistration{
		ID:       instance.ID,
		Name:     instance.Name,
		Address:  instance.Host,
		Port:     instance.Port,
		Meta:     instance.Metadata,
		CheckURL: instance.HealthCheckURL,
		Interval: 10 * time.Second,
		Timeout:  5 * time.Second,
	})
	if err != nil {
		return fmt.Errorf("register %s: %w", instance.ID, err)
	}
	return nil
}

// Deregister removes an instance from the registry.
func (r *ConsulServiceRegistry) Deregister(ctx context.Context, serviceID string) error {
	// Delegated to the Consul client in a full implementation.
	return nil
}

// Discover returns the currently healthy instances of a service.
func (r *ConsulServiceRegistry) Discover(ctx context.Context, serviceName string) ([]ServiceInstance, error) {
	instances, err := r.consul.HealthyInstances(ctx, serviceName)
	if err != nil {
		return nil, fmt.Errorf("discover %s: %w", serviceName, err)
	}
	return instances, nil
}

// Watch streams instance-set changes and invokes onChange for each update.
func (r *ConsulServiceRegistry) Watch(ctx context.Context, serviceName string, onChange func([]ServiceInstance)) error {
	// A full implementation runs Consul blocking queries in a goroutine that
	// exits when ctx is cancelled; omitted here for brevity.
	return nil
}

// LoadBalancedClient round-robins requests across discovered instances.
type LoadBalancedClient struct {
	registry    ServiceRegistry
	serviceName string
	http        *http.Client

	mu        sync.Mutex
	instances []ServiceInstance
	next      int
}

// NewLoadBalancedClient discovers the initial instance set and watches for
// changes.
func NewLoadBalancedClient(ctx context.Context, registry ServiceRegistry, serviceName string) (*LoadBalancedClient, error) {
	c := &LoadBalancedClient{
		registry:    registry,
		serviceName: serviceName,
		http:        &http.Client{Timeout: 5 * time.Second},
	}

	instances, err := registry.Discover(ctx, serviceName)
	if err != nil {
		return nil, fmt.Errorf("initial discover: %w", err)
	}
	c.setInstances(instances)

	if err := registry.Watch(ctx, serviceName, c.setInstances); err != nil {
		return nil, fmt.Errorf("watch %s: %w", serviceName, err)
	}
	return c, nil
}

func (c *LoadBalancedClient) setInstances(instances []ServiceInstance) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.instances = instances
}

// nextInstance returns the next instance in round-robin order.
func (c *LoadBalancedClient) nextInstance() (ServiceInstance, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.instances) == 0 {
		return ServiceInstance{}, fmt.Errorf("no instances available for %s", c.serviceName)
	}

	instance := c.instances[c.next%len(c.instances)]
	c.next++
	return instance, nil
}

// Get calls path on the next instance and decodes the JSON body into out.
func (c *LoadBalancedClient) Get(ctx context.Context, path string, out any) error {
	instance, err := c.nextInstance()
	if err != nil {
		return err
	}

	url := fmt.Sprintf("http://%s:%d%s", instance.Host, instance.Port, path)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("call %s: %w", instance.ID, err)
	}
	defer resp.Body.Close()

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}
```

## API Gateway Pattern

```go
package communication

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

// RouteConfig describes how the gateway forwards a matched request.
type RouteConfig struct {
	Path         string
	Service      string
	TargetPath   string
	Methods      []string
	RequiresAuth bool
	Timeout      time.Duration
}

// RateLimiter reports whether a client key may proceed.
type RateLimiter interface {
	Allow(key string) bool
}

// AuthService validates a bearer token and returns the authenticated user.
type AuthService interface {
	Validate(ctx context.Context, authorization string) (User, error)
}

// APIGateway authenticates, rate-limits, and forwards requests to services.
type APIGateway struct {
	registry ServiceRegistry
	breakers map[string]*CircuitBreaker
	limiter  RateLimiter
	auth     AuthService
	http     *http.Client

	mu     sync.Mutex
	routes map[string]RouteConfig
	next   int
}

// NewAPIGateway wires the gateway with its collaborators.
func NewAPIGateway(registry ServiceRegistry, breakers map[string]*CircuitBreaker, limiter RateLimiter, auth AuthService) *APIGateway {
	return &APIGateway{
		registry: registry,
		breakers: breakers,
		limiter:  limiter,
		auth:     auth,
		http:     &http.Client{},
		routes:   make(map[string]RouteConfig),
	}
}

// RegisterRoute adds a route to the gateway table.
func (g *APIGateway) RegisterRoute(cfg RouteConfig) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.routes[cfg.Path] = cfg
}

// ServeHTTP implements http.Handler: rate-limit, authenticate, then forward.
func (g *APIGateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !g.limiter.Allow(clientIP(r)) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "Too many requests"})
		return
	}

	route, ok := g.findRoute(r.URL.Path)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "Not found"})
		return
	}

	ctx := r.Context()
	var user User
	if route.RequiresAuth {
		authed, err := g.auth.Validate(ctx, r.Header.Get("Authorization"))
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Unauthorized"})
			return
		}
		user = authed
	}

	breaker := g.breakers[route.Service]
	err := breaker.Execute(ctx, func(ctx context.Context) error {
		instances, err := g.registry.Discover(ctx, route.Service)
		if err != nil {
			return fmt.Errorf("discover %s: %w", route.Service, err)
		}
		return g.forward(ctx, w, r, route, user, instances)
	})
	if err == nil {
		return
	}
	if errors.Is(err, ErrCircuitOpen) {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Service temporarily unavailable"})
		return
	}
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Internal server error"})
}

func (g *APIGateway) forward(ctx context.Context, w http.ResponseWriter, r *http.Request, route RouteConfig, user User, instances []ServiceInstance) error {
	if len(instances) == 0 {
		return fmt.Errorf("no instances for %s", route.Service)
	}
	instance := g.selectInstance(instances)

	ctx, cancel := context.WithTimeout(ctx, route.Timeout)
	defer cancel()

	targetURL := fmt.Sprintf("http://%s:%d%s", instance.Host, instance.Port, route.TargetPath)
	req, err := http.NewRequestWithContext(ctx, r.Method, targetURL, r.Body)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	g.transformHeaders(req, r, user)

	resp, err := g.http.Do(req)
	if err != nil {
		return fmt.Errorf("forward request: %w", err)
	}
	defer resp.Body.Close()

	w.WriteHeader(resp.StatusCode)
	if _, err := io.Copy(w, resp.Body); err != nil {
		return fmt.Errorf("copy response: %w", err)
	}
	return nil
}

func (g *APIGateway) selectInstance(instances []ServiceInstance) ServiceInstance {
	g.mu.Lock()
	defer g.mu.Unlock()
	instance := instances[g.next%len(instances)]
	g.next++
	return instance
}

func (g *APIGateway) transformHeaders(dst, src *http.Request, user User) {
	for key, values := range src.Header {
		if strings.EqualFold(key, "Authorization") {
			continue // strip the inbound credential
		}
		for _, v := range values {
			dst.Header.Add(key, v)
		}
	}

	// Add internal headers.
	dst.Header.Set("X-Request-ID", uuid.NewString())
	dst.Header.Set("X-Forwarded-For", src.Header.Get("X-Real-IP"))

	if user.ID != "" {
		dst.Header.Set("X-User-ID", user.ID)
		dst.Header.Set("X-User-Roles", strings.Join(user.Roles, ","))
	}
}

func (g *APIGateway) findRoute(path string) (RouteConfig, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for prefix, route := range g.routes {
		if strings.HasPrefix(path, strings.TrimSuffix(prefix, "*")) {
			return route, true
		}
	}
	return RouteConfig{}, false
}

func clientIP(r *http.Request) string {
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip
	}
	return r.RemoteAddr
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// Usage
func setupGateway(registry ServiceRegistry, breakers map[string]*CircuitBreaker, limiter RateLimiter, auth AuthService) *APIGateway {
	gateway := NewAPIGateway(registry, breakers, limiter, auth)

	gateway.RegisterRoute(RouteConfig{
		Path:         "/api/users/*",
		Service:      "user-service",
		TargetPath:   "/users/",
		Methods:      []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete},
		RequiresAuth: true,
		Timeout:      5 * time.Second,
	})

	gateway.RegisterRoute(RouteConfig{
		Path:         "/api/orders/*",
		Service:      "order-service",
		TargetPath:   "/orders/",
		Methods:      []string{http.MethodGet, http.MethodPost},
		RequiresAuth: true,
		Timeout:      10 * time.Second,
	})

	return gateway
}
```

## Communication Pattern Comparison

| Pattern | Latency | Coupling | Reliability | Complexity |
|---------|---------|----------|-------------|------------|
| REST | Low | High | Medium | Low |
| gRPC | Very Low | High | Medium | Medium |
| Message Queue | Medium | Low | High | Medium |
| Event-Driven | Medium | Very Low | High | High |

## When to Use

| Pattern | Use Case |
|---------|----------|
| REST | Public APIs, CRUD operations |
| gRPC | Internal services, streaming |
| Message Queue | Task processing, decoupling |
| Event-Driven | Complex workflows, eventual consistency |
