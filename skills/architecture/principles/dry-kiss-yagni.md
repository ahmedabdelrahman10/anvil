---
name: dry-kiss-yagni
description: Foundational software design principles
category: architecture/principles
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# DRY, KISS, YAGNI Principles

## Overview

Three complementary principles that guide software design toward
simplicity, maintainability, and pragmatism.

## DRY - Don't Repeat Yourself

> Every piece of knowledge must have a single, unambiguous,
> authoritative representation within a system.

### Bad Example
```go
// ❌ Duplicated validation logic
type UserController struct{}

func (c *UserController) CreateUser(ctx context.Context, in UserInput) error {
	// Validation duplicated here
	if in.Email == "" || !strings.Contains(in.Email, "@") {
		return errors.New("invalid email")
	}
	if len(in.Password) < 8 {
		return errors.New("password too short")
	}
	// ... create user
	return nil
}

func (c *UserController) UpdateUser(ctx context.Context, id string, in UserInput) error {
	// Same validation duplicated!
	if in.Email == "" || !strings.Contains(in.Email, "@") {
		return errors.New("invalid email")
	}
	if len(in.Password) < 8 {
		return errors.New("password too short")
	}
	// ... update user
	return nil
}
```

### Good Example
```go
// ✅ Single source of truth for validation

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

func validateEmail(email string) error {
	if email == "" || !strings.Contains(email, "@") {
		return &ValidationError{Field: "email", Message: "invalid email format"}
	}
	return nil
}

func validatePassword(password string) error {
	if len(password) < 8 {
		return &ValidationError{Field: "password", Message: "must be at least 8 characters"}
	}
	return nil
}

func validateUserInput(in UserInput) error {
	if err := validateEmail(in.Email); err != nil {
		return err
	}
	return validatePassword(in.Password)
}

type UserController struct{}

func (c *UserController) CreateUser(ctx context.Context, in UserInput) error {
	if err := validateUserInput(in); err != nil {
		return err
	}
	// ... create user
	return nil
}

func (c *UserController) UpdateUser(ctx context.Context, id string, in UserInput) error {
	if err := validateUserInput(in); err != nil {
		return err
	}
	// ... update user
	return nil
}
```

### DRY Applied to Different Levels

```go
// Configuration — one typed source, built once at startup.
// config/config.go
type Config struct {
	Host     string
	Port     int
	Database string
}

func Load() (Config, error) {
	port, err := strconv.Atoi(cmp.Or(os.Getenv("DB_PORT"), "5432"))
	if err != nil {
		return Config{}, fmt.Errorf("parse DB_PORT: %w", err)
	}
	return Config{
		Host:     os.Getenv("DB_HOST"),
		Port:     port,
		Database: os.Getenv("DB_NAME"),
	}, nil
}

// Constants — centralized, with a derived type.
// order/status.go
type OrderStatus string

const (
	OrderPending   OrderStatus = "pending"
	OrderConfirmed OrderStatus = "confirmed"
	OrderShipped   OrderStatus = "shipped"
	OrderDelivered OrderStatus = "delivered"
	OrderCancelled OrderStatus = "cancelled"
)

// Business rules — a single location.
// pricing/pricing.go
const (
	taxRate               = 0.10
	freeShippingThreshold = 100
	vipDiscount           = 0.15
)

func CalculateTax(amount float64) float64 {
	return amount * taxRate
}

func QualifiesForFreeShipping(amount float64) bool {
	return amount >= freeShippingThreshold
}
```

### When DRY Goes Wrong (WET - Write Everything Twice)

```go
// ❌ Over-DRY: unrelated operations forced together behind one flag
func Normalize(s, kind string) string {
	switch kind {
	case "email":
		return strings.TrimSpace(strings.ToLower(s))
	case "phone":
		return keepDigits(s)
	case "name":
		return titleCase(s)
	}
	return s
}

// ✅ Better: let them be separate — they'll evolve differently
func NormalizeEmail(email string) string {
	return strings.TrimSpace(strings.ToLower(email))
}

func NormalizePhone(phone string) string {
	var b strings.Builder
	for _, r := range phone {
		if unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func NormalizeName(name string) string {
	fields := strings.Fields(name)
	for i, f := range fields {
		fields[i] = strings.ToUpper(f[:1]) + strings.ToLower(f[1:])
	}
	return strings.Join(fields, " ")
}
```

## KISS - Keep It Simple, Stupid

> The simplest solution is usually the best solution.

### Bad Example
```go
// ❌ Over-engineered solution
type UserStatusManager struct {
	repo         UserRepository
	events       EventBus
	cache        CacheManager
	audit        AuditLogger
	stateMachine *StateMachine
	history      *StatusHistoryTracker
	notifier     *StatusChangeNotifier
	validator    *StatusTransitionValidator
}

func NewUserStatusManager(repo UserRepository, events EventBus, cache CacheManager, audit AuditLogger) *UserStatusManager {
	return &UserStatusManager{
		repo:         repo,
		events:       events,
		cache:        cache,
		audit:        audit,
		stateMachine: NewStateMachine(userStatusTransitions),
		history:      NewStatusHistoryTracker(cache),
		notifier:     NewStatusChangeNotifier(events),
		validator:    NewStatusTransitionValidator(),
	}
}

func (m *UserStatusManager) SetStatus(ctx context.Context, userID string, newStatus UserStatus) error {
	user, err := m.repo.FindByID(ctx, userID)
	if err != nil {
		return err
	}
	current := user.Status

	if err := m.validator.ValidateTransition(current, newStatus); err != nil {
		return err
	}
	if err := m.stateMachine.Transition(current, newStatus); err != nil {
		return err
	}
	if err := m.history.Record(ctx, userID, current, newStatus); err != nil {
		return err
	}

	user.Status = newStatus
	if err := m.repo.Save(ctx, user); err != nil {
		return err
	}

	if err := m.notifier.Notify(ctx, userID, newStatus); err != nil {
		return err
	}
	if err := m.audit.Log(ctx, "status_change", userID, current, newStatus); err != nil {
		return err
	}
	return m.cache.Invalidate(ctx, "user:"+userID)
}
```

### Good Example
```go
// ✅ Simple solution that meets the requirements
type UserStatus string

type UserService struct {
	repo UserRepository
}

func NewUserService(repo UserRepository) *UserService {
	return &UserService{repo: repo}
}

func (s *UserService) UpdateStatus(ctx context.Context, userID string, newStatus UserStatus) error {
	user, err := s.repo.FindByID(ctx, userID)
	if err != nil {
		return err
	}

	if !canTransition(user.Status, newStatus) {
		return fmt.Errorf("invalid status transition from %q to %q", user.Status, newStatus)
	}

	user.Status = newStatus
	return s.repo.Save(ctx, user)
}

func canTransition(from, to UserStatus) bool {
	allowed := map[UserStatus][]UserStatus{
		"pending":   {"active", "cancelled"},
		"active":    {"suspended", "cancelled"},
		"suspended": {"active", "cancelled"},
		"cancelled": {},
	}
	return slices.Contains(allowed[from], to)
}
```

### KISS Guidelines

```go
// ✅ Prefer the standard library / plain loops over hand-rolled generics
// Bad: reinventing iteration helpers
func Filter[T any](in []T, keep func(T) bool) []T { /* ... */ return nil }
func Map[T, U any](in []T, f func(T) U) []U       { /* ... */ return nil }

// Good: a plain loop (or the slices package) is clearer and needs no abstraction
func activeUsers(items []User) []User {
	var active []User
	for _, u := range items {
		if u.Active {
			active = append(active, u)
		}
	}
	return active
}

// ✅ Prefer flat over nested
// Bad: deep nesting
func authorizeNested(u *User) bool {
	if u != nil {
		if u.Active {
			if u.HasPermission("admin") {
				if u.EmailVerified {
					return true
				}
			}
		}
	}
	return false
}

// Good: guard clauses / early return
func authorize(u *User) bool {
	if u == nil {
		return false
	}
	if !u.Active {
		return false
	}
	if !u.HasPermission("admin") {
		return false
	}
	return u.EmailVerified
}

// ✅ Prefer explicit over clever
// Bad: a dense, hard-to-read expression
func indexBad(data Data) map[string]Item {
	return func() map[string]Item {
		m := map[string]Item{}
		for _, it := range data.Items {
			if it != nil {
				m[it.ID] = *it
			}
		}
		return m
	}()
}

// Good: clear, named steps
func indexByID(data Data) map[string]Item {
	result := make(map[string]Item, len(data.Items))
	for _, it := range data.Items {
		if it == nil {
			continue
		}
		result[it.ID] = *it
	}
	return result
}
```

## YAGNI - You Aren't Gonna Need It

> Don't implement functionality until it's actually needed.

### Bad Example
```go
// ❌ Over-engineering for hypothetical future needs
type UserService struct {
	repo          UserRepository
	cache         CacheService        // "we might need caching"
	analytics     AnalyticsService    // "we might want analytics"
	featureFlags  FeatureFlagService  // "we might need feature flags"
	audit         AuditService        // "we might need auditing"
	notifications NotificationService // "we might notify users"
}

func (s *UserService) CreateUser(ctx context.Context, in CreateUserInput) (*User, error) {
	// Check a feature flag for a "future" variation
	useNewFlow, _ := s.featureFlags.Enabled(ctx, "new_user_flow")
	_ = useNewFlow

	// Create the user with a "flexible" schema for future fields
	user, err := s.repo.Create(ctx, &User{
		Email:        in.Email,
		Metadata:     map[string]any{}, // "for future extensibility"
		Tags:         []string{},       // "we might need tags later"
		Preferences:  map[string]any{}, // "users might have preferences"
		CustomFields: map[string]any{}, // "for custom integrations"
	})
	if err != nil {
		return nil, err
	}

	_ = s.cache.InvalidatePattern(ctx, "users:*")       // "we might need"
	_ = s.analytics.Track(ctx, "user_created", user.ID) // "we might want"
	_ = s.audit.Log(ctx, "CREATE_USER", user)           // "for compliance"

	return user, nil
}
```

### Good Example
```go
// ✅ Implement what's needed now
type UserService struct {
	repo   UserRepository
	hasher PasswordHasher
}

func NewUserService(repo UserRepository, hasher PasswordHasher) *UserService {
	return &UserService{repo: repo, hasher: hasher}
}

func (s *UserService) CreateUser(ctx context.Context, in CreateUserInput) (*User, error) {
	hashed, err := s.hasher.Hash(in.Password)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}
	return s.repo.Create(ctx, &User{
		Email:    in.Email,
		Name:     in.Name,
		Password: hashed,
	})
}

// Add features when actually needed:
// - Caching: when performance becomes an issue
// - Analytics: when product needs the data
// - Audit logging: when compliance requires it
```

### YAGNI Checklist

| Question | If YES | If NO |
|----------|--------|-------|
| Is there a current requirement? | Build it | Don't build it |
| Will it be used this sprint? | Consider it | Defer it |
| Is the cost of adding later high? | Consider carefully | Defer it |
| Does the team have bandwidth? | Maybe | Definitely no |

### YAGNI vs Future-Proofing

```go
// ✅ Good future-proofing: a small interface allows change
type PaymentGateway interface {
	Charge(ctx context.Context, amount int64) (ChargeResult, error)
}

type StripeGateway struct{}

func (StripeGateway) Charge(ctx context.Context, amount int64) (ChargeResult, error) {
	// Stripe implementation
	return ChargeResult{}, nil
}

// ❌ Bad future-proofing: building implementations nobody uses yet
func NewGateway(kind string) (PaymentGateway, error) {
	switch kind {
	case "stripe":
		return StripeGateway{}, nil
	case "paypal", "square", "braintree":
		// three implementations built when only Stripe is needed
		return nil, fmt.Errorf("gateway %q not implemented", kind)
	default:
		return nil, fmt.Errorf("unknown gateway %q", kind)
	}
}
```

## Balancing the Principles

### Decision Matrix

| Scenario | DRY | KISS | YAGNI |
|----------|-----|------|-------|
| Duplicated code | Apply | - | - |
| Complex abstraction | - | Question | - |
| Future feature | - | - | Don't build |
| Third duplicate | Apply carefully | Keep simple | Build minimal |

### Practical Example

```go
// Scenario: building an e-commerce checkout

// ❌ Violates all three principles
type UniversalCheckoutProcessor struct{}

func (UniversalCheckoutProcessor) Process(ctx context.Context, cart Cart, opts CheckoutOptions) (Order, error) {
	// Supports 15 payment gateways (YAGNI — only 2 are used)
	// Complex routing logic (KISS violation)
	// Duplicates validation in several places (DRY violation)
	return Order{}, nil
}

// ✅ Follows all three principles
type CheckoutService struct {
	gateway   PaymentGateway // interface: future-proof but simple
	orders    OrderRepository
	inventory InventoryService
}

func NewCheckoutService(gateway PaymentGateway, orders OrderRepository, inventory InventoryService) *CheckoutService {
	return &CheckoutService{gateway: gateway, orders: orders, inventory: inventory}
}

func (s *CheckoutService) Checkout(ctx context.Context, cart Cart) (Order, error) {
	// Single validation point (DRY)
	if err := validateCart(cart); err != nil {
		return Order{}, err
	}

	// Simple, linear flow (KISS)
	if err := s.inventory.Reserve(ctx, cart.Items); err != nil {
		return Order{}, fmt.Errorf("reserve inventory: %w", err)
	}
	payment, err := s.gateway.Charge(ctx, cart.Total)
	if err != nil {
		return Order{}, fmt.Errorf("charge: %w", err)
	}
	return s.orders.Create(ctx, cart, payment)
}

func validateCart(cart Cart) error {
	if len(cart.Items) == 0 {
		return errors.New("cart is empty")
	}
	return nil
}
```

## Summary

| Principle | Focus | Question to Ask |
|-----------|-------|-----------------|
| DRY | Eliminate duplication | "Is this knowledge repeated?" |
| KISS | Reduce complexity | "Is this the simplest solution?" |
| YAGNI | Avoid speculation | "Do I need this right now?" |
