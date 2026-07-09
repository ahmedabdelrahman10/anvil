---
name: architecture-decision-records
description: Templates and practices for documenting architectural decisions
category: architecture/decision-making
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Architecture Decision Records (ADRs)

## Overview

Architecture Decision Records (ADRs) capture significant architectural decisions
along with their context and consequences. They provide a historical record of
why certain decisions were made, helping future developers understand the
reasoning behind the current architecture.

## ADR Template

```markdown
# ADR-{NUMBER}: {TITLE}

## Status

{Proposed | Accepted | Deprecated | Superseded by ADR-XXX}

## Date

{YYYY-MM-DD}

## Context

{Describe the issue motivating this decision. What is the problem
we're trying to solve? What constraints exist? What forces are at play?}

## Decision

{Describe the change proposed or decided. Use active voice:
"We will..." or "We have decided to..."}

## Consequences

### Positive
- {List positive consequences}

### Negative
- {List negative consequences}

### Neutral
- {List neutral observations}

## Alternatives Considered

### Alternative 1: {Name}
- **Pros**: {List advantages}
- **Cons**: {List disadvantages}
- **Why not chosen**: {Reason}

### Alternative 2: {Name}
- **Pros**: {List advantages}
- **Cons**: {List disadvantages}
- **Why not chosen**: {Reason}

## Related

- {Links to related ADRs, documents, or external references}
```

## Example ADRs

### ADR-001: Use PostgreSQL as Primary Database

```markdown
# ADR-001: Use PostgreSQL as Primary Database

## Status

Accepted

## Date

2024-01-15

## Context

We need to select a primary database for our e-commerce platform.
The platform needs to handle:
- Complex queries for product search and filtering
- Transactional integrity for order processing
- JSON storage for flexible product attributes
- Geographic queries for store locator feature
- Expected scale of 10M products, 1M daily active users

Team expertise: Strong SQL background, limited NoSQL experience.
Budget: Open-source preferred to minimize licensing costs.

## Decision

We will use PostgreSQL 16 as our primary database.

## Consequences

### Positive
- ACID compliance ensures data integrity for financial transactions
- Rich indexing (B-tree, GIN, GiST) supports complex queries
- JSONB enables flexible schema for product attributes
- PostGIS extension provides geographic capabilities
- Excellent tooling ecosystem (pgAdmin, DataGrip, etc.)
- Team has existing PostgreSQL expertise
- No licensing costs

### Negative
- Single-node writes limit horizontal write scaling
- Need to plan for read replicas as traffic grows
- Complex sharding if we exceed single-node capacity
- JSON queries slower than dedicated document stores

### Neutral
- Will need connection pooling (PgBouncer) for high concurrency
- Regular VACUUM maintenance required
- Need monitoring setup (pg_stat_statements, etc.)

## Alternatives Considered

### Alternative 1: MongoDB
- **Pros**: Flexible schema, horizontal scaling built-in, JSON-native
- **Cons**: Limited transaction support, eventual consistency concerns
- **Why not chosen**: Financial transactions require strong consistency;
  team would need significant training

### Alternative 2: MySQL
- **Pros**: Widely used, good performance, team familiar
- **Cons**: Less powerful JSON support, PostGIS alternative (MySQL GIS)
  less mature, fewer advanced features
- **Why not chosen**: PostgreSQL's advanced features (JSONB, PostGIS,
  full-text search) better fit our requirements

### Alternative 3: CockroachDB
- **Pros**: PostgreSQL-compatible, distributed by design
- **Cons**: Newer technology, smaller community, potential hidden costs
- **Why not chosen**: Premature optimization; can migrate if needed

## Related

- ADR-002: Database Connection Pooling Strategy
- ADR-005: Read Replica Configuration
- Technical Spec: Database Schema Design
```

### ADR-002: Adopt Microservices Architecture

```markdown
# ADR-002: Adopt Microservices Architecture

## Status

Accepted

## Date

2024-01-20

## Context

Our monolithic application has grown to 500K lines of code with:
- 15 developers across 3 teams
- 2-week deployment cycles due to coordination overhead
- Frequent merge conflicts in shared code
- Single point of failure affecting entire platform
- Different scaling needs: checkout (bursty) vs catalog (read-heavy)

Business is growing 200% YoY, requiring faster feature delivery.

## Decision

We will decompose the monolith into microservices, starting with:
1. Order Service
2. Inventory Service
3. User Service
4. Catalog Service
5. Payment Service

We will use:
- Kubernetes for orchestration
- gRPC for internal communication
- REST for external APIs
- Kafka for event-driven communication

## Consequences

### Positive
- Independent deployments enable faster releases
- Teams can own services end-to-end
- Services can scale independently based on load
- Technology flexibility per service
- Failure isolation prevents cascading failures

### Negative
- Increased operational complexity
- Network latency between services
- Distributed transaction challenges
- Need for robust monitoring and tracing
- Higher infrastructure costs initially
- Team needs to learn new patterns (saga, circuit breaker)

### Neutral
- Need to establish service boundaries carefully
- API versioning becomes critical
- Data consistency model changes from ACID to eventual
- Testing strategy needs revision (contract tests, integration tests)

## Alternatives Considered

### Alternative 1: Modular Monolith
- **Pros**: Simpler operations, easier transactions, lower latency
- **Cons**: Still coupled deployments, shared database bottleneck
- **Why not chosen**: Doesn't solve team autonomy and scaling issues

### Alternative 2: Serverless Functions
- **Pros**: Maximum scalability, pay-per-use
- **Cons**: Cold starts, vendor lock-in, complex local development
- **Why not chosen**: Business logic complexity doesn't fit function model

## Related

- ADR-003: Service Communication Patterns
- ADR-004: Distributed Tracing Strategy
- ADR-008: API Gateway Selection
```

### ADR-003: Event Sourcing for Order Domain

```markdown
# ADR-003: Event Sourcing for Order Domain

## Status

Accepted

## Date

2024-02-01

## Context

Order management requires:
- Complete audit trail of all changes
- Ability to reconstruct order state at any point
- Support for complex business processes (returns, partial fulfillment)
- Integration with multiple downstream systems (inventory, shipping, accounting)
- Regulatory compliance requiring change history

Current CRUD approach loses change history and creates tight coupling.

## Decision

We will implement Event Sourcing for the Order domain:
- Store events as the source of truth
- Build projections for query optimization
- Use CQRS to separate read and write models

Technology choices:
- EventStoreDB for event storage
- PostgreSQL for read projections
- Kafka for publishing events to other services

## Consequences

### Positive
- Complete audit trail built-in
- Can replay events to rebuild state or create new projections
- Natural fit for event-driven architecture
- Enables temporal queries ("order state at time X")
- Decoupled from downstream consumers via events

### Negative
- Steeper learning curve for team
- Eventually consistent read models
- Event schema evolution complexity
- More storage required (events are immutable)
- Debugging requires understanding event sequence

### Neutral
- Need to design events carefully (not too fine, not too coarse)
- Snapshot strategy needed for aggregates with many events
- Projection rebuild process must be planned
- Testing approach changes (event-driven tests)

## Alternatives Considered

### Alternative 1: Traditional CRUD with Audit Table
- **Pros**: Simple, familiar pattern, immediate consistency
- **Cons**: Audit separate from main model, no temporal queries
- **Why not chosen**: Doesn't provide complete business event history

### Alternative 2: Event Sourcing All Domains
- **Pros**: Consistent architecture across platform
- **Cons**: Overkill for simple CRUD domains (user profile, etc.)
- **Why not chosen**: Complexity not justified for all domains

## Related

- ADR-002: Adopt Microservices Architecture
- ADR-006: CQRS Implementation Guidelines
- Technical Spec: Order Event Schema
```

## ADR Lifecycle

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│ Proposed │────►│ Accepted │────►│Deprecated│
└──────────┘     └──────────┘     └──────────┘
                       │                │
                       │                ▼
                       │          ┌───────────┐
                       └─────────►│Superseded │
                                  └───────────┘
```

## ADR Organization

```
docs/
└── architecture/
    └── decisions/
        ├── README.md           # Index of all ADRs
        ├── 0001-use-postgresql.md
        ├── 0002-adopt-microservices.md
        ├── 0003-event-sourcing-orders.md
        ├── 0004-distributed-tracing.md
        └── templates/
            └── adr-template.md
```

## ADR Index Template

```markdown
# Architecture Decision Records

## Active Decisions

| ID | Title | Date | Status |
|----|-------|------|--------|
| [ADR-001](0001-use-postgresql.md) | Use PostgreSQL as Primary Database | 2024-01-15 | Accepted |
| [ADR-002](0002-adopt-microservices.md) | Adopt Microservices Architecture | 2024-01-20 | Accepted |
| [ADR-003](0003-event-sourcing-orders.md) | Event Sourcing for Order Domain | 2024-02-01 | Accepted |

## Superseded Decisions

| ID | Title | Superseded By |
|----|-------|---------------|
| [ADR-005](0005-use-rabbitmq.md) | Use RabbitMQ for Messaging | ADR-010 |

## Deprecated Decisions

| ID | Title | Deprecation Date |
|----|-------|------------------|
| None | | |
```

## Best Practices

### When to Write an ADR

- Choosing between multiple viable options
- Decision has significant impact on architecture
- Decision is difficult or expensive to change
- Decision affects multiple teams or components
- You find yourself explaining "why" repeatedly

### Writing Effective ADRs

```go
// Guidelines for ADR content.

// ADRGuidelines describes the content an effective ADR should capture.
type ADRGuidelines struct {
	Context      ADRContext
	Decision     ADRDecision
	Consequences ADRConsequences
	Alternatives []ADRAlternative
}

// ADRContext describes the forces at play.
type ADRContext struct {
	Constraints  []string // Technical, business, regulatory
	Requirements []string // What must be satisfied
	Assumptions  []string // What we believe to be true
}

// ADRDecision states the decision; be specific and actionable.
type ADRDecision struct {
	What string // The actual decision
	Why  string // Brief rationale
	How  string // Implementation approach
}

// ADRConsequences is an honest account of the trade-offs.
type ADRConsequences struct {
	Positive []string // Benefits gained
	Negative []string // Costs incurred
	Neutral  []string // Neither good nor bad
	Risks    []string // Potential future issues
}

// ADRAlternative records an option considered; show due diligence.
type ADRAlternative struct {
	Name       string
	Considered bool
	Reason     string // Why not chosen
}
```

### Review Process

1. **Draft**: Author creates ADR in "Proposed" status
2. **Review**: Team reviews and provides feedback
3. **Discuss**: Address concerns, update ADR
4. **Decide**: Team reaches consensus or escalates
5. **Accept**: Change status to "Accepted"
6. **Implement**: Execute the decision
7. **Maintain**: Update if circumstances change

## Benefits

| Benefit | Description |
|---------|-------------|
| Historical Context | Understand why decisions were made |
| Onboarding | New team members learn architecture faster |
| Consistency | Reduces re-litigation of decisions |
| Communication | Stakeholders informed of changes |
| Learning | Capture lessons from past decisions |

## When to Use

- Significant architectural choices
- Technology selections
- Pattern adoptions
- Breaking changes
- Security-related decisions
- Cross-team impacts
