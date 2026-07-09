---
name: documentation
description: Best practices for documenting software architecture
category: architecture/decision-making
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Architecture Documentation

## Overview

Good architecture documentation helps teams understand, maintain, and evolve
systems. It should be accurate, accessible, and maintainable—avoiding both
over-documentation and under-documentation.

## Documentation Levels

```
┌─────────────────────────────────────────────────────────────┐
│                 DOCUMENTATION PYRAMID                        │
│                                                             │
│                      ┌─────────┐                            │
│                      │  Code   │  ← Self-documenting code   │
│                      └────┬────┘                            │
│                     ┌─────┴─────┐                           │
│                     │ API Docs  │  ← OpenAPI, JSDoc         │
│                     └─────┬─────┘                           │
│                   ┌───────┴───────┐                         │
│                   │ Architecture  │  ← C4, ADRs, diagrams   │
│                   └───────┬───────┘                         │
│                 ┌─────────┴─────────┐                       │
│                 │    Runbooks      │  ← Operations guides    │
│                 └─────────┬─────────┘                       │
│               ┌───────────┴───────────┐                     │
│               │    Onboarding        │  ← Getting started    │
│               └───────────────────────┘                     │
│                                                             │
│  More specific ▲                         ▼ More general     │
└─────────────────────────────────────────────────────────────┘
```

## C4 Model

### Level 1: System Context

```go
// Documents the system and its relationships with users and other systems.

// SystemContext documents a system and its relationships with users and
// other systems.
type SystemContext struct {
	System          System
	People          []Person
	ExternalSystems []ExternalSystem
	Relationships   []Relationship
}

// System identifies the software system being documented.
type System struct {
	Name        string
	Description string
	Technology  string // optional
}

// exampleEcommerceContext builds the C4 system-context for the platform.
func exampleEcommerceContext() SystemContext {
	return SystemContext{
		System: System{
			Name:        "E-Commerce Platform",
			Description: "Allows customers to browse products and place orders",
		},
		People: []Person{
			{Name: "Customer", Description: "Browses and purchases products"},
			{Name: "Admin", Description: "Manages products and orders"},
		},
		ExternalSystems: []ExternalSystem{
			{Name: "Payment Gateway", Description: "Processes credit card payments"},
			{Name: "Shipping Provider", Description: "Handles order fulfillment"},
			{Name: "Email Service", Description: "Sends transactional emails"},
		},
		Relationships: []Relationship{
			{From: "Customer", To: "E-Commerce Platform", Description: "Uses"},
			{From: "E-Commerce Platform", To: "Payment Gateway", Description: "Processes payments via"},
		},
	}
}
```

```
┌─────────────────────────────────────────────────────────────┐
│                    SYSTEM CONTEXT                            │
│                                                             │
│    ┌──────────┐                      ┌──────────────┐       │
│    │ Customer │──────Uses───────────►│  E-Commerce  │       │
│    └──────────┘                      │   Platform   │       │
│                                      └──────┬───────┘       │
│    ┌──────────┐                             │               │
│    │  Admin   │──────Manages────────────────┤               │
│    └──────────┘                             │               │
│                                             │               │
│            ┌────────────────────────────────┼───────┐       │
│            │                                │       │       │
│            ▼                                ▼       ▼       │
│    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│    │   Payment    │  │   Shipping   │  │    Email     │    │
│    │   Gateway    │  │   Provider   │  │   Service    │    │
│    └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Level 2: Container Diagram

```go
// Shows the high-level technical building blocks.

// ContainerDiagram shows the high-level technical building blocks.
type ContainerDiagram struct {
	Containers    []Container
	Relationships []ContainerRelationship
}

// ContainerType enumerates the kinds of container in a C4 diagram.
type ContainerType string

const (
	ContainerWebApp    ContainerType = "web-app"
	ContainerMobileApp ContainerType = "mobile-app"
	ContainerAPI       ContainerType = "api"
	ContainerDatabase  ContainerType = "database"
	ContainerQueue     ContainerType = "queue"
	ContainerFileStore ContainerType = "file-store"
)

// Container is a deployable or runnable technical building block.
type Container struct {
	Name        string
	Type        ContainerType
	Technology  string
	Description string
}

// exampleEcommerceContainers builds the container diagram for the platform.
func exampleEcommerceContainers() ContainerDiagram {
	return ContainerDiagram{
		Containers: []Container{
			{
				Name:        "Web Application",
				Type:        ContainerWebApp,
				Technology:  "React",
				Description: "Customer-facing storefront",
			},
			{
				Name:        "API Gateway",
				Type:        ContainerAPI,
				Technology:  "Kong",
				Description: "Routes and rate-limits API requests",
			},
			{
				Name:        "Order Service",
				Type:        ContainerAPI,
				Technology:  "Go",
				Description: "Handles order processing",
			},
			{
				Name:        "Order Database",
				Type:        ContainerDatabase,
				Technology:  "PostgreSQL",
				Description: "Stores order data",
			},
			{
				Name:        "Message Queue",
				Type:        ContainerQueue,
				Technology:  "RabbitMQ",
				Description: "Async communication between services",
			},
		},
		Relationships: []ContainerRelationship{
			{From: "Web Application", To: "API Gateway", Protocol: "HTTPS", Description: "API calls"},
			{From: "API Gateway", To: "Order Service", Protocol: "HTTP", Description: "Routes requests"},
			{From: "Order Service", To: "Order Database", Protocol: "TCP", Description: "Reads/writes data"},
			{From: "Order Service", To: "Message Queue", Protocol: "AMQP", Description: "Publishes events"},
		},
	}
}
```

### Level 3: Component Diagram

```go
// Shows the internal structure of a container.

// ComponentDiagram shows the internal structure of a container.
type ComponentDiagram struct {
	Container     string
	Components    []Component
	Relationships []ComponentRelationship
}

// Component is a grouping of related functionality inside a container.
type Component struct {
	Name           string
	Responsibility string
	Technology     string // optional
}

// exampleOrderServiceComponents builds the component diagram for the order service.
func exampleOrderServiceComponents() ComponentDiagram {
	return ComponentDiagram{
		Container: "Order Service",
		Components: []Component{
			{Name: "OrderHandler", Responsibility: "Handles HTTP requests", Technology: "net/http handler"},
			{Name: "OrderService", Responsibility: "Business logic orchestration", Technology: "domain service"},
			{Name: "OrderRepository", Responsibility: "Data access abstraction", Technology: "pgx repository"},
			{Name: "PaymentClient", Responsibility: "Payment gateway integration", Technology: "HTTP client"},
			{Name: "EventPublisher", Responsibility: "Publishes domain events", Technology: "RabbitMQ client"},
		},
		Relationships: []ComponentRelationship{
			{From: "OrderHandler", To: "OrderService", Description: "Uses"},
			{From: "OrderService", To: "OrderRepository", Description: "Persists via"},
			{From: "OrderService", To: "PaymentClient", Description: "Processes payments via"},
			{From: "OrderService", To: "EventPublisher", Description: "Publishes events via"},
		},
	}
}
```

### Level 4: Code

```go
// Use code comments and self-documenting code at this level.

// OrderService handles order lifecycle operations.
//
// Responsibilities:
//   - Validate order data
//   - Process payments via PaymentClient
//   - Persist orders via OrderRepository
//   - Publish events for downstream systems
//
// Example:
//
//	order, err := svc.PlaceOrder(ctx, CreateOrderRequest{
//		CustomerID: "cust-123",
//		Items:      []OrderItem{{ProductID: "prod-1", Quantity: 2}},
//	})
type OrderService struct {
	orders   OrderRepository
	payments PaymentClient
	events   EventPublisher
}

// NewOrderService wires an OrderService from its collaborators. It accepts
// interfaces so callers stay decoupled from concrete implementations.
func NewOrderService(orders OrderRepository, payments PaymentClient, events EventPublisher) *OrderService {
	return &OrderService{orders: orders, payments: payments, events: events}
}

// PlaceOrder places a new order.
//
// Flow:
//  1. Validate order data
//  2. Calculate totals
//  3. Process payment
//  4. Save order
//  5. Publish OrderPlaced event
//
// It returns ErrInvalidOrder if the order data is invalid and wraps any
// payment failure from the payment client.
func (s *OrderService) PlaceOrder(ctx context.Context, req CreateOrderRequest) (*Order, error) {
	// Implementation.
	panic("not implemented")
}
```

## API Documentation

### OpenAPI/Swagger

```yaml
openapi: 3.0.3
info:
  title: Order Service API
  version: 1.0.0
  description: |
    API for managing orders in the e-commerce platform.

    ## Authentication
    All endpoints require Bearer token authentication.

    ## Rate Limiting
    - 100 requests per minute for standard users
    - 1000 requests per minute for premium users

paths:
  /orders:
    post:
      summary: Create a new order
      operationId: createOrder
      tags:
        - Orders
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateOrderRequest'
            example:
              customerId: "cust-123"
              items:
                - productId: "prod-456"
                  quantity: 2
              shippingAddress:
                street: "123 Main St"
                city: "Tokyo"
                postalCode: "100-0001"
      responses:
        '201':
          description: Order created successfully
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Order'
        '400':
          description: Invalid request data
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Error'
        '402':
          description: Payment failed
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/PaymentError'

components:
  schemas:
    CreateOrderRequest:
      type: object
      required:
        - customerId
        - items
      properties:
        customerId:
          type: string
          description: Customer identifier
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderItem'
          minItems: 1
        shippingAddress:
          $ref: '#/components/schemas/Address'

    Order:
      type: object
      properties:
        id:
          type: string
          format: uuid
        status:
          type: string
          enum: [pending, confirmed, shipped, delivered, cancelled]
        total:
          type: number
          format: decimal
        createdAt:
          type: string
          format: date-time
```

## Runbooks

### Template

```markdown
# Runbook: {Service/Process Name}

## Overview
Brief description of the service and its role in the system.

## Quick Reference

| Item | Value |
|------|-------|
| Service URL | https://order-service.internal |
| Health Check | GET /health |
| Logs | Datadog: `service:order-service` |
| Dashboards | [Grafana](link) |
| On-Call | #platform-oncall |

## Common Operations

### Restart Service
```bash
kubectl rollout restart deployment/order-service -n production
```

### Scale Up
```bash
kubectl scale deployment/order-service --replicas=10 -n production
```

### Check Logs
```bash
kubectl logs -l app=order-service -n production --tail=100
```

## Alerts

### High Error Rate
**Trigger**: Error rate > 1% for 5 minutes
**Impact**: Customer orders may be failing
**Steps**:
1. Check recent deployments: `kubectl rollout history deployment/order-service`
2. Check downstream services: Payment, Inventory
3. Check database connectivity
4. If recent deploy, rollback: `kubectl rollout undo deployment/order-service`

### High Latency
**Trigger**: P99 latency > 2s for 5 minutes
**Impact**: Poor customer experience
**Steps**:
1. Check database slow queries
2. Check external service latency
3. Consider scaling up pods

## Disaster Recovery

### Database Restore
```bash
# List available backups
aws s3 ls s3://backups/order-db/

# Restore from backup
pg_restore -h $DB_HOST -d orders backup.dump
```

## Contacts
- Service Owner: @order-team
- Database: @platform-db
- Escalation: @engineering-manager
```

## README Templates

### Repository README

```markdown
# Order Service

Microservice responsible for order management in the e-commerce platform.

## Quick Start

```bash
# Prerequisites
- Go 1.22+
- Docker
- PostgreSQL 15+

# Setup
go mod download
cp .env.example .env
make migrate

# Run
go run ./cmd/order-service

# Test
go test ./...
```

## Architecture

```
.
├── cmd/
│   └── order-service/  # main package / entrypoint
└── internal/
    ├── order/          # domain models + business logic
    ├── httpapi/        # HTTP handlers
    ├── postgres/       # data access
    ├── events/         # event definitions
    └── platform/       # external integrations
```

## API Documentation

- [OpenAPI Spec](./docs/openapi.yaml)
- [Swagger UI](http://localhost:3000/docs) (when running locally)

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | - |
| `RABBITMQ_URL` | RabbitMQ connection string | - |
| `PAYMENT_SERVICE_URL` | Payment service endpoint | - |

## Development

### Running Tests
```bash
go test ./...                       # Unit tests
go test -tags=e2e ./...             # End-to-end tests
go test -cover ./...                # With coverage
```

### Database Migrations
```bash
migrate -path ./migrations -database "$DATABASE_URL" up      # Run migrations
migrate create -ext sql -dir ./migrations <name>             # Create new migration
migrate -path ./migrations -database "$DATABASE_URL" down 1  # Rollback last migration
```

## Deployment

Deployed via GitHub Actions to Kubernetes.
- `main` → Production
- `develop` → Staging

## Related

- [Architecture Decision Records](./docs/adr/)
- [Runbook](./docs/runbook.md)
- [API Documentation](./docs/api.md)
```

## Documentation Best Practices

### Keep Documentation Close to Code

```
project/
├── internal/
│   └── order/
│       ├── README.md           # Module-specific docs
│       ├── service.go
│       └── handler.go
├── docs/
│   ├── architecture/
│   │   ├── c4-diagrams/
│   │   └── adr/
│   ├── api/
│   │   └── openapi.yaml
│   └── runbooks/
├── README.md                    # Project overview
└── CONTRIBUTING.md              # How to contribute
```

### Documentation as Code

```go
// Use tools that generate docs from code.

// godoc renders package comments and exported symbols at pkg.go.dev.

// CalculateTotal calculates the total price of an order.
//
// items is the list of order items. discountPercent is an optional discount
// in the range 0-100; pass 0 for no discount. It returns the calculated total.
//
// Example:
//
//	total := CalculateTotal([]OrderItem{
//		{Price: 10, Quantity: 2},
//		{Price: 5, Quantity: 1},
//	}, 10)
//	// total == 22.50 (10% discount applied)
func CalculateTotal(items []OrderItem, discountPercent float64) float64 {
	var subtotal float64
	for _, item := range items {
		subtotal += item.Price * float64(item.Quantity)
	}
	if discountPercent > 0 {
		return subtotal * (1 - discountPercent/100)
	}
	return subtotal
}
```

### Living Documentation

```go
// Generate documentation from tests; the subtest names describe behavior.

func TestOrderService_PlaceOrder(t *testing.T) {
	t.Run("creates order with valid items", func(t *testing.T) {
		// Given
		items := []OrderItem{{ProductID: "prod-1", Quantity: 2}}

		// When
		order, err := svc.PlaceOrder(ctx, CreateOrderRequest{CustomerID: "cust-1", Items: items})

		// Then
		require.NoError(t, err)
		assert.Equal(t, StatusPending, order.Status)
		assert.Len(t, order.Items, 1)
	})

	t.Run("rejects order with empty items", func(t *testing.T) {
		// Given
		var items []OrderItem

		// When / Then
		_, err := svc.PlaceOrder(ctx, CreateOrderRequest{CustomerID: "cust-1", Items: items})
		require.ErrorContains(t, err, "order must have at least one item")
	})

	t.Run("processes payment before confirming order", func(t *testing.T) {
		// Given
		order := createPendingOrder(t)

		// When
		require.NoError(t, svc.ConfirmOrder(ctx, order.ID))

		// Then
		payments.AssertChargedWith(t, order.Total)
		assert.Equal(t, StatusConfirmed, order.Status)
	})
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Onboarding | New team members ramp up faster |
| Maintenance | Understand system before changing it |
| Communication | Stakeholders understand architecture |
| Decision Support | Context for future decisions |
| Compliance | Audit requirements met |

## When to Document

- New systems or significant changes
- Decisions with long-term impact
- Non-obvious design choices
- Integration points
- Operational procedures
- Security considerations
