# Architecture Principles Reference

## SOLID Principles

### Single Responsibility Principle (SRP)

> A type should have only one reason to change.

```go
// ❌ Multiple responsibilities on one type
type User struct {
	ID, Name, Email string
}

func (u *User) Save() error            { /* database */ return nil }
func (u *User) SendEmail() error       { /* email    */ return nil }
func (u *User) GenerateReport() string { /* report   */ return "" }

// ✅ Split: User holds data; each responsibility gets its own type.
// type User struct{ ID, Name, Email string }  // data only

type UserRepository struct{ db *sql.DB }

func (r *UserRepository) Save(ctx context.Context, u User) error { return nil } // database only

type UserEmailService struct{ mailer Mailer }

func (s *UserEmailService) SendWelcomeEmail(ctx context.Context, u User) error { return nil } // email only
```

### Open/Closed Principle (OCP)

> Open for extension, closed for modification.

```go
// ❌ Must modify to add payment types
type PaymentProcessor struct{}

func (p *PaymentProcessor) Process(kind string, amount int64) error {
	switch kind {
	case "credit_card": // ...
	case "paypal": // ...
		// must add a new case for every type
	}
	return nil
}

// ✅ Open for extension via new implementations
type PaymentMethod interface {
	Process(ctx context.Context, amount int64) (PaymentResult, error)
}

type CreditCardPayment struct{}

func (CreditCardPayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	return PaymentResult{}, nil
}

type PayPalPayment struct{}

func (PayPalPayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	return PaymentResult{}, nil
}

// Add a new method without touching existing code.
type StripePayment struct{}

func (StripePayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	return PaymentResult{}, nil
}
```

### Liskov Substitution Principle (LSP)

> Subtypes must be substitutable for their base types.

```go
// ❌ Square breaks Rectangle's contract (embedding to fake inheritance)
type Rectangle struct{ width, height float64 }

func (r *Rectangle) SetWidth(w float64)  { r.width = w }
func (r *Rectangle) SetHeight(h float64) { r.height = h }

type Square struct{ Rectangle }

func (s *Square) SetWidth(w float64) {
	s.width = w
	s.height = w // violates the base type's expected behavior!
}

// ✅ Model shared behavior with an interface, not inheritance.
type Shape interface {
	Area() float64
}

type Rectangle struct{ width, height float64 }

func (r Rectangle) Area() float64 { return r.width * r.height }

type Square struct{ side float64 }

func (s Square) Area() float64 { return s.side * s.side }
```

### Interface Segregation Principle (ISP)

> Clients should not depend on interfaces they don't use.

```go
// ❌ Fat interface forces unnecessary methods
type Worker interface {
	Work()
	Eat()
	Sleep()
}

type Robot struct{}

func (Robot) Work()  { /* OK */ }
func (Robot) Eat()   { panic("robots don't eat") }   // forced!
func (Robot) Sleep() { panic("robots don't sleep") } // forced!

// ✅ Segregated, single-method interfaces
type Worker interface{ Work() }
type Eater interface{ Eat() }
type Sleeper interface{ Sleep() }

type Human struct{}

func (Human) Work()  { /* ... */ }
func (Human) Eat()   { /* ... */ }
func (Human) Sleep() { /* ... */ }

type Robot struct{}

func (Robot) Work() { /* ... */ } // no Eat/Sleep needed
```

### Dependency Inversion Principle (DIP)

> Depend on abstractions, not concretions.

```go
// ❌ High-level type depends on a concrete low-level type
type UserService struct {
	db *MySQLDatabase // tight coupling!
}

func (s *UserService) CreateUser(ctx context.Context, data UserData) error {
	return s.db.Save(ctx, data)
}

// ✅ Both depend on an abstraction the consumer defines.
type Database interface {
	Save(ctx context.Context, data any) error
	Find(ctx context.Context, query any) (any, error)
}

type MySQLDatabase struct{}      // implements Database
type PostgreSQLDatabase struct{} // implements Database

type UserService struct {
	db Database // injected!
}

func NewUserService(db Database) *UserService { return &UserService{db: db} }

func (s *UserService) CreateUser(ctx context.Context, data UserData) error {
	if err := s.db.Save(ctx, data); err != nil {
		return fmt.Errorf("save user: %w", err)
	}
	return nil
}

// Easy to switch implementations:
//   svc := NewUserService(&PostgreSQLDatabase{})
```

## Core Design Principles

### DRY (Don't Repeat Yourself)

```go
// ❌ Duplicated validation
func createUser(email string) error {
	if !emailRe.MatchString(email) {
		return errors.New("invalid email")
	}
	return nil
}

func updateEmail(email string) error {
	if !emailRe.MatchString(email) {
		return errors.New("invalid email")
	}
	return nil
}

// ✅ Single source of truth: a validated value type
var emailRe = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

type Email struct{ value string }

func NewEmail(value string) (Email, error) {
	if !emailRe.MatchString(value) {
		return Email{}, fmt.Errorf("invalid email: %q", value)
	}
	return Email{value: strings.ToLower(value)}, nil
}

func (e Email) String() string { return e.value }
```

### KISS (Keep It Simple, Stupid)

```go
// ❌ Over-engineered
type UserManagerFactoryBuilder struct {
	config   BuilderConfiguration
	strategy FactoryStrategy
	// ... 200 lines of abstraction
}

func (b *UserManagerFactoryBuilder) CreateUserManager() UserManager {
	return newUserManager(b.config)
}

// ✅ Simple and direct
type UserService struct{ repo UserRepository }

func NewUserService(repo UserRepository) *UserService { return &UserService{repo: repo} }

func (s *UserService) GetUser(ctx context.Context, id string) (*User, error) {
	return s.repo.FindByID(ctx, id)
}

func (s *UserService) CreateUser(ctx context.Context, data CreateUserData) (*User, error) {
	u, err := NewUser(data)
	if err != nil {
		return nil, fmt.Errorf("build user: %w", err)
	}
	if err := s.repo.Save(ctx, u); err != nil {
		return nil, fmt.Errorf("save user: %w", err)
	}
	return u, nil
}
```

### YAGNI (You Aren't Gonna Need It)

```go
// ❌ Speculative fields
type User struct {
	ID                string
	Name              string
	Email             string
	FutureFeatureFlag bool           // "we might need this"
	LegacySystemID    string         // "just in case"
	AnalyticsMetadata map[string]any // "could be useful"
}

// ✅ Only what's needed now
type User struct {
	ID    string
	Name  string
	Email string
}
```

### Separation of Concerns

```go
// ❌ Mixed concerns in one handler
func (c *OrderController) CreateOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	_ = json.NewDecoder(r.Body).Decode(&req)

	// validation
	if len(req.Items) == 0 {
		http.Error(w, "items required", http.StatusBadRequest)
		return
	}

	// business logic
	var total int64
	for _, i := range req.Items {
		total += i.Price * int64(i.Qty)
	}

	// persistence: db.ExecContext(ctx, "INSERT INTO orders ...")
	// notification: emailService.Send(ctx, req.CustomerEmail, "Order confirmed")
}

// ✅ Separated concerns
// Controller — HTTP handling only
type OrderController struct{ createOrder *CreateOrderUseCase }

func (c *OrderController) CreateOrder(w http.ResponseWriter, r *http.Request) {
	dto, err := decodeCreateOrder(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	res, err := c.createOrder.Execute(r.Context(), dto)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(res)
}

// Use case — business logic
type CreateOrderUseCase struct {
	orders        OrderRepository
	notifications NotificationService
}

func (uc *CreateOrderUseCase) Execute(ctx context.Context, dto CreateOrderDTO) (OrderResponse, error) {
	order, err := NewOrder(dto.Items)
	if err != nil {
		return OrderResponse{}, fmt.Errorf("build order: %w", err)
	}
	if err := uc.orders.Save(ctx, order); err != nil {
		return OrderResponse{}, fmt.Errorf("save order: %w", err)
	}
	if err := uc.notifications.OrderCreated(ctx, order); err != nil {
		return OrderResponse{}, fmt.Errorf("notify: %w", err)
	}
	return toOrderResponse(order), nil
}

// Repository — persistence only
type OrderRepository interface {
	Save(ctx context.Context, o *Order) error
}

// Service — notifications only
type NotificationService interface {
	OrderCreated(ctx context.Context, o *Order) error
}
```

## Dependency Inversion in Practice

### Constructor Injection

```go
// Preferred — explicit dependencies via a constructor.
type OrderService struct {
	orders   OrderRepository
	payments PaymentGateway
	email    EmailService
}

func NewOrderService(orders OrderRepository, payments PaymentGateway, email EmailService) *OrderService {
	return &OrderService{orders: orders, payments: payments, email: email}
}
```

### Interface-Based Dependencies

```go
// The consumer package defines the interface it needs.
type OrderRepository interface {
	Save(ctx context.Context, o *Order) error
	FindByID(ctx context.Context, id OrderID) (*Order, error)
}

// Infrastructure implements it.
type PostgresOrderRepository struct{ db *sql.DB }

func NewPostgresOrderRepository(db *sql.DB) *PostgresOrderRepository {
	return &PostgresOrderRepository{db: db}
}

func (r *PostgresOrderRepository) Save(ctx context.Context, o *Order) error {
	if _, err := r.db.ExecContext(ctx, "INSERT INTO orders ...", toRow(o)); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	return nil
}

func (r *PostgresOrderRepository) FindByID(ctx context.Context, id OrderID) (*Order, error) {
	row := r.db.QueryRowContext(ctx, "SELECT * FROM orders WHERE id = $1", id.Value())
	o, err := scanOrder(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find order %s: %w", id.Value(), err)
	}
	return o, nil
}
```

### Wiring at the Composition Root

```go
// Wire concrete implementations to interfaces explicitly in one place.
func newApp(db *sql.DB) *OrderService {
	orders := NewPostgresOrderRepository(db)
	payments := NewStripePaymentGateway()
	email := NewSendGridEmailService()
	return NewOrderService(orders, payments, email)
}

// For large graphs, generate the wiring with google/wire or uber-go/fx
// rather than a reflective runtime container.
```

## Common Violations

| Principle | Violation Sign | Fix |
|-----------|----------------|-----|
| SRP | Type name contains "and" | Split into focused types |
| OCP | Switch/if on a type field | Use polymorphism (interfaces) |
| LSP | Method returns "not implemented" | Prefer composition over embedding |
| ISP | Implements unused methods | Split the interface |
| DIP | Concrete construction inside a struct | Inject the dependency |
| DRY | Copy-pasted code | Extract to a function/type |
| KISS | "Future-proofing" | Build only what's needed |
