---
name: trade-offs
description: Framework for analyzing and communicating architectural trade-offs
category: architecture/decision-making
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Architectural Trade-offs

## Overview

Every architectural decision involves trade-offs. Understanding and
communicating these trade-offs is essential for making informed decisions
and setting appropriate expectations with stakeholders.

## The CAP Theorem

```
┌─────────────────────────────────────────────────────────────┐
│                    CAP THEOREM                               │
│                                                             │
│                    Consistency                              │
│                        ▲                                    │
│                       / \                                   │
│                      /   \                                  │
│                     /     \                                 │
│                    /  CA   \                                │
│                   /         \                               │
│                  /           \                              │
│ Availability ◄──────────────────► Partition Tolerance       │
│                  \           /                              │
│                   \   AP   /                                │
│                    \       /                                │
│                     \ CP  /                                 │
│                      \   /                                  │
│                       \ /                                   │
│                                                             │
│  In distributed systems, pick two:                          │
│  CA: Single-node systems (PostgreSQL, traditional RDBMS)    │
│  CP: Consistent but may be unavailable (HBase, MongoDB)     │
│  AP: Available but eventually consistent (Cassandra, DynamoDB)│
└─────────────────────────────────────────────────────────────┘
```

## Common Trade-off Dimensions

### Performance vs Maintainability

```go
// Trade-off: inline everything for performance vs modular code.

// ProcessOrderOptimized favors performance: everything is inlined to
// minimise function calls. Harder to maintain.
func ProcessOrderOptimized(order RawOrder) ProcessedOrder {
	var total, tax, discount float64
	for _, item := range order.Items {
		itemTotal := item.Price * float64(item.Quantity)
		total += itemTotal

		// Inline tax calculation.
		if item.Taxable {
			tax += itemTotal * 0.08
		}

		// Inline discount calculation.
		if order.CouponCode != "" && item.Discountable {
			discount += itemTotal * 0.1
		}
	}

	return ProcessedOrder{
		Total:      total,
		Tax:        tax,
		Discount:   discount,
		GrandTotal: total + tax - discount,
	}
}

// ProcessOrderMaintainable favors clarity: each concern is a named function.
// Slightly slower due to the extra calls.
func ProcessOrderMaintainable(order RawOrder) ProcessedOrder {
	itemTotals := calculateItemTotals(order.Items)
	tax := calculateTax(order.Items, itemTotals)
	discount := calculateDiscount(order, itemTotals)
	total := sumTotals(itemTotals)

	return ProcessedOrder{
		Total:      total,
		Tax:        tax,
		Discount:   discount,
		GrandTotal: total + tax - discount,
	}
}

// Decision factors:
//   - How often is this code modified? (maintainability wins)
//   - Is this in a hot path? (performance may win)
//   - What's the actual performance difference? (measure!)
```

### Consistency vs Availability

```go
// Trade-off: strong consistency vs high availability.

// StrongConsistencyOrderService uses a synchronous distributed transaction:
// all steps succeed or all fail. Lower availability.
type StrongConsistencyOrderService struct {
	coordinator TransactionCoordinator
	inventory   InventoryService
	payments    PaymentService
	orders      OrderRepository
}

// NewStrongConsistencyOrderService wires the service from its collaborators.
func NewStrongConsistencyOrderService(
	coordinator TransactionCoordinator,
	inventory InventoryService,
	payments PaymentService,
	orders OrderRepository,
) *StrongConsistencyOrderService {
	return &StrongConsistencyOrderService{
		coordinator: coordinator,
		inventory:   inventory,
		payments:    payments,
		orders:      orders,
	}
}

func (s *StrongConsistencyOrderService) PlaceOrder(ctx context.Context, order Order) (OrderResult, error) {
	txn, err := s.coordinator.BeginTransaction(ctx)
	if err != nil {
		return OrderResult{}, fmt.Errorf("begin transaction: %w", err)
	}

	// All must succeed or all fail; order fails if any service is down.
	if err := s.inventory.Reserve(ctx, txn, order.Items); err != nil {
		_ = txn.Rollback(ctx)
		return OrderResult{}, fmt.Errorf("reserve inventory: %w", err)
	}
	if err := s.payments.Charge(ctx, txn, order.Total); err != nil {
		_ = txn.Rollback(ctx)
		return OrderResult{}, fmt.Errorf("charge payment: %w", err)
	}
	if err := s.orders.Save(ctx, txn, order); err != nil {
		_ = txn.Rollback(ctx)
		return OrderResult{}, fmt.Errorf("save order: %w", err)
	}

	if err := txn.Commit(ctx); err != nil {
		return OrderResult{}, fmt.Errorf("commit transaction: %w", err)
	}
	return OrderResult{Success: true, OrderID: order.ID}, nil
}

// HighAvailabilityOrderService accepts the order locally and processes it
// asynchronously. Always available, eventually consistent.
type HighAvailabilityOrderService struct {
	orders    OrderRepository
	events    EventBus
	inventory InventoryService
	payments  PaymentService
}

// NewHighAvailabilityOrderService wires the service from its collaborators.
func NewHighAvailabilityOrderService(
	orders OrderRepository,
	events EventBus,
	inventory InventoryService,
	payments PaymentService,
) *HighAvailabilityOrderService {
	return &HighAvailabilityOrderService{
		orders:    orders,
		events:    events,
		inventory: inventory,
		payments:  payments,
	}
}

func (s *HighAvailabilityOrderService) PlaceOrder(ctx context.Context, order Order) (OrderResult, error) {
	// Save order locally first (always available).
	order.Status = StatusPending
	if err := s.orders.Save(ctx, order); err != nil {
		return OrderResult{}, fmt.Errorf("save order: %w", err)
	}

	// Publish events for async processing.
	event := OrderPlacedEvent{OrderID: order.ID, Items: order.Items, Total: order.Total}
	if err := s.events.Publish(ctx, event); err != nil {
		return OrderResult{}, fmt.Errorf("publish order placed: %w", err)
	}

	// Order accepted, will be processed eventually.
	return OrderResult{Success: true, OrderID: order.ID, Status: StatusPending}, nil
}

// HandleOrderPlaced processes an accepted order asynchronously.
func (s *HighAvailabilityOrderService) HandleOrderPlaced(ctx context.Context, event OrderPlacedEvent) error {
	if err := s.process(ctx, event); err != nil {
		// Compensating action: move the order to a failed state.
		if updErr := s.orders.UpdateStatus(ctx, event.OrderID, StatusFailed); updErr != nil {
			return errors.Join(err, fmt.Errorf("mark failed: %w", updErr))
		}
		return s.compensate(ctx, event)
	}
	return nil
}

func (s *HighAvailabilityOrderService) process(ctx context.Context, event OrderPlacedEvent) error {
	if err := s.inventory.Reserve(ctx, event.Items); err != nil {
		return fmt.Errorf("reserve inventory: %w", err)
	}
	if err := s.payments.Charge(ctx, event.Total); err != nil {
		return fmt.Errorf("charge payment: %w", err)
	}
	if err := s.orders.UpdateStatus(ctx, event.OrderID, StatusConfirmed); err != nil {
		return fmt.Errorf("confirm order: %w", err)
	}
	return nil
}
```

### Simplicity vs Flexibility

```go
// Trade-off: simple, opinionated vs flexible, complex.

// SimpleConfig is opinionated: fixed choices, few knobs.
type SimpleConfig struct {
	DatabaseURL string
	Port        int
	LogLevel    string // "debug" | "info" | "warn" | "error"
}

// SimpleApp wires fixed architecture decisions from SimpleConfig.
type SimpleApp struct {
	db     *PostgresDatabase
	server *HTTPServer
	logger *SlogLogger
}

// NewSimpleApp builds a SimpleApp with fixed collaborators.
func NewSimpleApp(cfg SimpleConfig) *SimpleApp {
	return &SimpleApp{
		db:     NewPostgresDatabase(cfg.DatabaseURL),
		server: NewHTTPServer(cfg.Port),
		logger: NewSlogLogger(cfg.LogLevel),
	}
}

// FlexibleConfig exposes many options at the cost of complexity.
type FlexibleConfig struct {
	Database DatabaseConfig
	Server   ServerConfig
	Logging  LoggingConfig
}

// DatabaseConfig selects and tunes the database backend.
type DatabaseConfig struct {
	Type        string             // "postgres" | "mysql" | "mongodb" | "dynamodb"
	Connection  map[string]any     // driver-specific settings
	PoolSize    int                // optional
	SSL         *SSLConfig         // optional
	Replication *ReplicationConfig // optional
}

// ServerConfig selects and tunes the HTTP server.
type ServerConfig struct {
	Type       string             // "net/http" | "chi" | "gin" | "echo"
	Port       int                //
	Middleware []MiddlewareConfig // optional
	CORS       *CORSConfig        // optional
	RateLimit  *RateLimitConfig   // optional
}

// LoggingConfig selects and tunes the logging backend.
type LoggingConfig struct {
	Type        string // "console" | "file" | "cloudwatch" | "datadog"
	Level       string //
	Format      string // "json" | "text"
	Destination string // optional
}

// FlexibleApp wires collaborators chosen at runtime from FlexibleConfig.
type FlexibleApp struct {
	db     Database
	server Server
	logger Logger
}

// NewFlexibleApp builds each collaborator via a factory keyed by config.
func NewFlexibleApp(cfg FlexibleConfig) *FlexibleApp {
	return &FlexibleApp{
		db:     NewDatabase(cfg.Database),
		server: NewServer(cfg.Server),
		logger: NewLogger(cfg.Logging),
	}
}

// Decision factors:
//   - How many use cases need to be supported?
//   - Who will configure this? (developers vs operators)
//   - What's the cost of wrong defaults?
```

## Trade-off Analysis Framework

```go
// TradeoffAnalysis captures a structured comparison of options.
type TradeoffAnalysis struct {
	Decision       string
	Options        []Option
	Criteria       []Criterion
	Evaluation     EvaluationMatrix
	Recommendation Recommendation
}

// Option is one candidate under consideration.
type Option struct {
	Name        string
	Description string
}

// Criterion is a weighted dimension the options are scored against.
type Criterion struct {
	Name        string
	Weight      int // 1-10 importance
	Description string
}

// EvaluationMatrix holds scores keyed by option, then criterion.
type EvaluationMatrix struct {
	Scores map[string]map[string]int // option -> criterion -> score
}

// Recommendation is the chosen option with its justification.
type Recommendation struct {
	ChosenOption string
	Rationale    string
	Risks        []string
	Mitigations  []string
}

// exampleDatabaseSelection builds a worked database-selection analysis.
func exampleDatabaseSelection() TradeoffAnalysis {
	return TradeoffAnalysis{
		Decision: "Select primary database for e-commerce platform",
		Options: []Option{
			{Name: "PostgreSQL", Description: "Open-source relational database"},
			{Name: "MongoDB", Description: "Document-oriented NoSQL database"},
			{Name: "DynamoDB", Description: "AWS managed NoSQL database"},
		},
		Criteria: []Criterion{
			{Name: "Consistency", Weight: 9, Description: "ACID compliance for transactions"},
			{Name: "Scalability", Weight: 7, Description: "Ability to handle growth"},
			{Name: "Query Flexibility", Weight: 8, Description: "Complex query support"},
			{Name: "Operational Cost", Weight: 6, Description: "Total cost of ownership"},
			{Name: "Team Expertise", Weight: 7, Description: "Existing team knowledge"},
			{Name: "Ecosystem", Weight: 5, Description: "Tools, libraries, community"},
		},
		Evaluation: EvaluationMatrix{
			Scores: map[string]map[string]int{
				"PostgreSQL": {
					"Consistency":       10,
					"Scalability":       6,
					"Query Flexibility": 9,
					"Operational Cost":  7,
					"Team Expertise":    9,
					"Ecosystem":         9,
				},
				"MongoDB": {
					"Consistency":       6,
					"Scalability":       8,
					"Query Flexibility": 7,
					"Operational Cost":  6,
					"Team Expertise":    4,
					"Ecosystem":         8,
				},
				"DynamoDB": {
					"Consistency":       7,
					"Scalability":       10,
					"Query Flexibility": 4,
					"Operational Cost":  8,
					"Team Expertise":    3,
					"Ecosystem":         6,
				},
			},
		},
		Recommendation: Recommendation{
			ChosenOption: "PostgreSQL",
			Rationale: "PostgreSQL scores highest on weighted criteria " +
				"(342 vs MongoDB 275 vs DynamoDB 263). Key factors: strong " +
				"consistency for financial transactions, team expertise, and " +
				"query flexibility for complex product searches.",
			Risks: []string{
				"Write scaling limited to single node initially",
				"Need read replicas for high traffic",
			},
			Mitigations: []string{
				"Plan for read replica setup at 10K concurrent users",
				"Evaluate Citus or partitioning if write scaling needed",
			},
		},
	}
}
```

## Visualizing Trade-offs

### Radar Chart Comparison

```
                    Consistency
                         10
                          │
                          │
       Ecosystem  8 ──────┼────── 8  Scalability
                    \     │     /
                     \    │    /
                      \   │   /
                       \  │  /
            Team  6 ────\ │ /──── 6  Cost
           Expertise     \│/
                          │
                          │
                    Query Flex

        ── PostgreSQL    -- MongoDB    ·· DynamoDB
```

### Decision Matrix Table

| Criterion | Weight | PostgreSQL | MongoDB | DynamoDB |
|-----------|--------|------------|---------|----------|
| Consistency | 9 | 10 (90) | 6 (54) | 7 (63) |
| Scalability | 7 | 6 (42) | 8 (56) | 10 (70) |
| Query Flexibility | 8 | 9 (72) | 7 (56) | 4 (32) |
| Operational Cost | 6 | 7 (42) | 6 (36) | 8 (48) |
| Team Expertise | 7 | 9 (63) | 4 (28) | 3 (21) |
| Ecosystem | 5 | 9 (45) | 8 (40) | 6 (30) |
| **Weighted Total** | | **354** | **270** | **264** |

## Common Trade-off Patterns

### Build vs Buy

```go
// BuildVsBuyAnalysis frames a build-or-buy decision.
type BuildVsBuyAnalysis struct {
	Option string // "build" | "buy"
	Build  BuildFactors
	Buy    BuyFactors
}

// BuildFactors are the considerations favoring building in-house.
type BuildFactors struct {
	Customization          string  // "high" | "medium" | "low"
	CompetitiveAdvantage   bool    //
	TeamCapability         bool    //
	TimeToMarketMonths     int     // months
	MaintenanceCostPerYear float64 // per year
}

// BuyFactors are the considerations favoring buying off the shelf.
type BuyFactors struct {
	FitToRequirements       string  // "perfect" | "good" | "poor"
	VendorStability         string  // "high" | "medium" | "low"
	LicenseCostPerYear      float64 // per year
	IntegrationPersonMonths int     // person-months
	LockInRisk              string  // "high" | "medium" | "low"
}

// Decision heuristics:
// BUILD when:
//   - Core differentiator for your business
//   - No suitable solution exists
//   - Team has expertise and capacity
//   - Long-term cost of ownership is lower
//
// BUY when:
//   - Commodity functionality (auth, payments, email)
//   - Time to market is critical
//   - Vendor solution is mature and well-supported
//   - Internal expertise is lacking
```

### Synchronous vs Asynchronous

```go
// SyncAsyncDecision frames a synchronous-vs-asynchronous choice.
type SyncAsyncDecision struct {
	Operation string
	Sync      SyncIndicators
	Async     AsyncIndicators
}

// SyncIndicators point toward handling the operation synchronously.
type SyncIndicators struct {
	UserWaitsForResult        bool //
	OperationIsFast           bool // < 500ms
	StrongConsistencyRequired bool //
	SimpleErrorHandling       bool //
}

// AsyncIndicators point toward handling the operation asynchronously.
type AsyncIndicators struct {
	LongRunningOperation      bool // > 1s
	CanBeProcessedLater       bool //
	NeedsRetryLogic           bool //
	CrossServiceOrchestration bool //
	UserCanBePollNotified     bool //
}

// Examples:
// SYNC:  Login validation, add to cart, get product details
// ASYNC: Order processing, report generation, bulk imports
```

### Monolith vs Microservices

```go
// ArchitectureStyleDecision frames a monolith-vs-microservices choice.
type ArchitectureStyleDecision struct {
	Factors ArchitectureFactors
}

// ArchitectureFactors are the inputs to the style decision.
type ArchitectureFactors struct {
	TeamSize            int    //
	DeploymentFrequency string // "daily" | "weekly" | "monthly"
	ScalingRequirements string // "uniform" | "varied"
	DomainComplexity    string // "simple" | "moderate" | "complex"
	OperationalMaturity string // "low" | "medium" | "high"
}

// Monolith indicators:
//   - Small team (< 10 developers)
//   - Simple domain
//   - Uniform scaling needs
//   - Low operational maturity
//   - Early stage product
//
// Microservices indicators:
//   - Large team (> 20 developers)
//   - Complex domain with clear boundaries
//   - Different scaling needs per component
//   - High operational maturity
//   - Mature product with proven domain model
```

## Communicating Trade-offs

### To Technical Stakeholders

```markdown
## Trade-off Summary: Event Sourcing

### We're Trading:
- **Complexity** for **Auditability**
- **Immediate Consistency** for **Scalability**
- **Simple Queries** for **Temporal Queries**

### Quantified Impact:
| Metric | Before | After |
|--------|--------|-------|
| Write Latency | 5ms | 8ms (+60%) |
| Storage | 100GB | 300GB (+200%) |
| Query Complexity | Simple SQL | Projections required |
| Audit Coverage | 40% | 100% |
| Rebuild Time | N/A | 2 hours for full rebuild |

### Risk Mitigation:
- Snapshot strategy reduces rebuild time to 10 minutes
- Read projections optimize common queries
- Team training planned for Q2
```

### To Business Stakeholders

```markdown
## Trade-off Summary: Database Selection

### Business Impact

**Option A: PostgreSQL**
- ✅ Proven reliability for financial transactions
- ✅ No licensing costs
- ⚠️ May need infrastructure investment at scale
- 📊 Supports current + 3-year growth projection

**Option B: Cloud-Managed Database**
- ✅ Automatic scaling, less operational burden
- ❌ Higher monthly cost ($5K → $15K/month)
- ⚠️ Vendor lock-in limits future options

### Recommendation
PostgreSQL for Phase 1, with planned evaluation of managed options
at 100K daily users (projected: Month 18).
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Informed Decisions | Understand full implications before committing |
| Stakeholder Alignment | Everyone understands what's being traded |
| Future Reference | Document why trade-offs were accepted |
| Risk Management | Identify and plan for negative consequences |

## When to Analyze Trade-offs

- Architectural decisions affecting multiple components
- Technology selections with long-term implications
- Performance optimizations with complexity cost
- Security measures affecting usability
- Scalability changes affecting consistency
