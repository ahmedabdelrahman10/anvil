# Decision Making Reference

## Architecture Decision Records (ADRs)

### Template

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

## Related
- {Links to related ADRs, documents, or external references}
```

### Example: Database Selection

```markdown
# ADR-001: Use PostgreSQL as Primary Database

## Status
Accepted

## Date
2024-01-15

## Context
We need to select a primary database for our e-commerce platform.
Requirements:
- Complex queries for product search and filtering
- Transactional integrity for order processing
- JSON storage for flexible product attributes
- Geographic queries for store locator
- Expected scale: 10M products, 1M daily active users

Team expertise: Strong SQL background.
Budget: Open-source preferred.

## Decision
We will use PostgreSQL 16 as our primary database.

## Consequences

### Positive
- ACID compliance for financial transactions
- Rich indexing (B-tree, GIN, GiST) for complex queries
- JSONB for flexible schema
- PostGIS for geographic features
- No licensing costs

### Negative
- Single-node writes limit horizontal scaling
- Need read replicas as traffic grows
- Complex sharding if we exceed single-node capacity

### Neutral
- Need connection pooling (PgBouncer) for high concurrency
- Regular VACUUM maintenance required

## Alternatives Considered

### Alternative 1: MongoDB
- **Pros**: Flexible schema, horizontal scaling, JSON-native
- **Cons**: Limited transactions, eventual consistency
- **Why not chosen**: Financial transactions need strong consistency

### Alternative 2: MySQL
- **Pros**: Widely used, good performance
- **Cons**: Less powerful JSON support, weaker PostGIS alternative
- **Why not chosen**: PostgreSQL's advanced features better fit requirements
```

### Example: Architecture Selection

```markdown
# ADR-002: Adopt Microservices Architecture

## Status
Accepted

## Date
2024-01-20

## Context
Monolithic application has grown to 500K lines with:
- 15 developers across 3 teams
- 2-week deployment cycles
- Frequent merge conflicts
- Single point of failure
- Different scaling needs (checkout: bursty, catalog: read-heavy)

Business growing 200% YoY, requiring faster feature delivery.

## Decision
Decompose into microservices:
1. Order Service
2. Inventory Service
3. User Service
4. Catalog Service
5. Payment Service

Technology: Kubernetes, gRPC internal, REST external, Kafka events.

## Consequences

### Positive
- Independent deployments
- Team ownership end-to-end
- Independent scaling
- Failure isolation

### Negative
- Increased operational complexity
- Network latency between services
- Distributed transaction challenges
- Need robust monitoring

### Neutral
- Service boundaries must be designed carefully
- API versioning becomes critical
- Testing strategy changes (contract tests)

## Alternatives Considered

### Alternative 1: Modular Monolith
- **Pros**: Simpler operations, easier transactions
- **Cons**: Still coupled deployments, shared database
- **Why not chosen**: Doesn't solve team autonomy issues

### Alternative 2: Serverless Functions
- **Pros**: Maximum scalability, pay-per-use
- **Cons**: Cold starts, vendor lock-in, complex local dev
- **Why not chosen**: Business logic too complex for function model
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

## Organization

```
docs/
└── architecture/
    └── decisions/
        ├── README.md           # Index of all ADRs
        ├── 0001-use-postgresql.md
        ├── 0002-adopt-microservices.md
        ├── 0003-event-sourcing-orders.md
        └── templates/
            └── adr-template.md
```

## When to Write an ADR

- Choosing between multiple viable options
- Decision has significant impact on architecture
- Decision is difficult or expensive to change
- Decision affects multiple teams or components
- You find yourself explaining "why" repeatedly

## Trade-off Analysis

### Evaluation Matrix

| Criterion | Weight | Option A | Option B | Option C |
|-----------|--------|----------|----------|----------|
| Performance | 0.25 | 4 | 3 | 5 |
| Maintainability | 0.20 | 5 | 4 | 3 |
| Team Expertise | 0.20 | 5 | 3 | 2 |
| Cost | 0.15 | 4 | 5 | 3 |
| Scalability | 0.20 | 3 | 4 | 5 |
| **Weighted Score** | | **4.15** | **3.75** | **3.60** |

### Decision Criteria

```go
type DecisionCriteria struct {
	Functional struct {
		MustHave   []string // non-negotiable requirements
		NiceToHave []string // preferred features
	}
	NonFunctional struct {
		Performance string // latency, throughput targets
		Scalability string // growth expectations
		Reliability string // uptime requirements
		Security    string // compliance, data protection
	}
	Constraints struct {
		Budget     string // cost limits
		Timeline   string // delivery deadlines
		Team       string // skills available
		Technology string // existing tech stack
	}
}
```

### Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Technology obsolescence | Medium | High | Choose widely-adopted technology |
| Team skill gap | High | Medium | Training plan, documentation |
| Vendor lock-in | Low | High | Abstract integration points |
| Performance issues | Medium | High | Load testing, capacity planning |

## Review Process

1. **Draft**: Author creates ADR in "Proposed" status
2. **Review**: Team reviews and provides feedback
3. **Discuss**: Address concerns, update ADR
4. **Decide**: Team reaches consensus or escalates
5. **Accept**: Change status to "Accepted"
6. **Implement**: Execute the decision
7. **Maintain**: Update if circumstances change

## Documentation Guidelines

### Writing Effective ADRs

```
Context:
  - Describe forces at play
  - Technical, business, regulatory constraints
  - What must be satisfied (requirements)
  - What we believe to be true (assumptions)

Decision:
  - Be specific and actionable
  - The actual decision (what)
  - Brief rationale (why)
  - Implementation approach (how)

Consequences:
  - Be honest about trade-offs
  - Benefits gained (positive)
  - Costs incurred (negative)
  - Neither good nor bad (neutral)
  - Potential future issues (risks)

Alternatives:
  - Show due diligence
  - Name each alternative
  - Document why not chosen
```

## Benefits of ADRs

| Benefit | Description |
|---------|-------------|
| Historical Context | Understand why decisions were made |
| Onboarding | New team members learn architecture faster |
| Consistency | Reduces re-litigation of decisions |
| Communication | Stakeholders informed of changes |
| Learning | Capture lessons from past decisions |

## Decision Anti-patterns

| Anti-pattern | Problem | Solution |
|--------------|---------|----------|
| Analysis Paralysis | Too much analysis, no decision | Set decision deadline |
| HIPPO | Highest Paid Person's Opinion | Use objective criteria |
| Groupthink | Everyone agrees too easily | Assign devil's advocate |
| Resume-Driven | Choose for personal gain | Focus on project needs |
| Sunk Cost | Can't abandon failed approach | Evaluate objectively |
