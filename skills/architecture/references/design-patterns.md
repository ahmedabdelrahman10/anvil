# Design Patterns Reference

## Creational Patterns

### Factory Method

```go
// A constructor function is Go's factory — no factory type needed.
type PaymentProcessor interface {
	Process(ctx context.Context, amount int64) (PaymentResult, error)
}

type ProcessorFactory func(cfg Config) PaymentProcessor

func newStripeProcessor(cfg Config) PaymentProcessor { return &StripeProcessor{cfg: cfg} }
func newPayPalProcessor(cfg Config) PaymentProcessor { return &PayPalProcessor{cfg: cfg} }

// Select the factory by type.
func processorFactory(kind string) (ProcessorFactory, error) {
	switch kind {
	case "stripe":
		return newStripeProcessor, nil
	case "paypal":
		return newPayPalProcessor, nil
	default:
		return nil, fmt.Errorf("unknown payment type: %q", kind)
	}
}
```

### Abstract Factory

```go
// Create families of related objects behind one interface.
type UIFactory interface {
	Button() Button
	Input() Input
	Modal() Modal
}

type MaterialUIFactory struct{}

func (MaterialUIFactory) Button() Button { return MaterialButton{} }
func (MaterialUIFactory) Input() Input   { return MaterialInput{} }
func (MaterialUIFactory) Modal() Modal   { return MaterialModal{} }

type AntDesignFactory struct{}

func (AntDesignFactory) Button() Button { return AntButton{} }
func (AntDesignFactory) Input() Input   { return AntInput{} }
func (AntDesignFactory) Modal() Modal   { return AntModal{} }

// Usage — depends only on the interface.
func buildForm(f UIFactory) (Button, Input) {
	return f.Button(), f.Input()
}
```

### Builder

```go
// Separate step-by-step construction from representation.
// (Go often prefers functional options for constructors; a fluent builder
// still fits accretive structures like a query.)
type QueryBuilder struct {
	cols    []string
	table   string
	wheres  []string
	orderBy []string
}

func NewQueryBuilder() *QueryBuilder { return &QueryBuilder{} }

func (b *QueryBuilder) Select(cols ...string) *QueryBuilder {
	b.cols = append(b.cols, cols...)
	return b
}
func (b *QueryBuilder) From(table string) *QueryBuilder { b.table = table; return b }
func (b *QueryBuilder) Where(cond string) *QueryBuilder { b.wheres = append(b.wheres, cond); return b }

func (b *QueryBuilder) OrderBy(col, dir string) *QueryBuilder {
	if dir == "" {
		dir = "ASC"
	}
	b.orderBy = append(b.orderBy, col+" "+dir)
	return b
}

func (b *QueryBuilder) Build() string {
	q := "SELECT " + strings.Join(b.cols, ", ") + " FROM " + b.table
	if len(b.wheres) > 0 {
		q += " WHERE " + strings.Join(b.wheres, " AND ")
	}
	if len(b.orderBy) > 0 {
		q += " ORDER BY " + strings.Join(b.orderBy, ", ")
	}
	return q
}

// Usage
func example() {
	query := NewQueryBuilder().
		Select("id", "name", "email").
		From("users").
		Where("active = true").
		Where("created_at > NOW() - INTERVAL '30 days'").
		OrderBy("created_at", "DESC").
		Build()
	_ = query
}
```

### Singleton

```go
// Ensure a single instance with a lazy, thread-safe initializer.
type Configuration struct {
	values map[string]string
}

var (
	configOnce     sync.Once
	configInstance *Configuration
)

func Config() *Configuration {
	configOnce.Do(func() {
		configInstance = &Configuration{values: loadFromEnvironment()}
	})
	return configInstance
}

func (c *Configuration) Get(key string) (string, bool) {
	v, ok := c.values[key]
	return v, ok
}

// Prefer dependency injection over a singleton in most cases.
// Reserve singletons for configuration, logging, or connection pools.
```

## Structural Patterns

### Adapter

```go
// Convert one interface into the interface clients expect.
type ModernPaymentGateway interface {
	Charge(ctx context.Context, amount Money, card CardDetails) (PaymentResult, error)
}

// Legacy system with an incompatible interface.
type LegacyPaymentSystem struct{}

func (LegacyPaymentSystem) ProcessPayment(cents int64, cardNumber, expiry, cvv string) bool {
	return true // legacy implementation
}

type LegacyPaymentAdapter struct{ legacy *LegacyPaymentSystem }

func NewLegacyPaymentAdapter(legacy *LegacyPaymentSystem) *LegacyPaymentAdapter {
	return &LegacyPaymentAdapter{legacy: legacy}
}

func (a *LegacyPaymentAdapter) Charge(ctx context.Context, amount Money, card CardDetails) (PaymentResult, error) {
	if !a.legacy.ProcessPayment(amount.Cents(), card.Number, card.Expiry, card.CVV) {
		return PaymentResult{}, errors.New("legacy payment declined")
	}
	return PaymentResult{Success: true, TransactionID: uuid.NewString()}, nil
}

// Usage
func example(ctx context.Context) {
	var gateway ModernPaymentGateway = NewLegacyPaymentAdapter(&LegacyPaymentSystem{})
	_, _ = gateway.Charge(ctx, mustMoney(100, "USD"), CardDetails{})
}
```

### Decorator

```go
// Attach responsibilities dynamically by wrapping an interface.
type DataSource interface {
	Read() (string, error)
	Write(data string) error
}

type FileDataSource struct{ filename string }

func NewFileDataSource(filename string) *FileDataSource { return &FileDataSource{filename: filename} }

func (f *FileDataSource) Read() (string, error) {
	b, err := os.ReadFile(f.filename)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", f.filename, err)
	}
	return string(b), nil
}

func (f *FileDataSource) Write(data string) error {
	if err := os.WriteFile(f.filename, []byte(data), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", f.filename, err)
	}
	return nil
}

// Decorators embed the wrapped DataSource and override selectively.
type EncryptionDecorator struct{ DataSource }

func (d EncryptionDecorator) Read() (string, error) {
	raw, err := d.DataSource.Read()
	if err != nil {
		return "", err
	}
	return decrypt(raw), nil
}

func (d EncryptionDecorator) Write(data string) error { return d.DataSource.Write(encrypt(data)) }

type CompressionDecorator struct{ DataSource }

func (d CompressionDecorator) Read() (string, error) {
	raw, err := d.DataSource.Read()
	if err != nil {
		return "", err
	}
	return decompress(raw), nil
}

func (d CompressionDecorator) Write(data string) error { return d.DataSource.Write(compress(data)) }

// Usage — decorators stack via embedding.
func example() error {
	var src DataSource = NewFileDataSource("data.txt")
	src = EncryptionDecorator{src}
	src = CompressionDecorator{src}
	return src.Write("sensitive data") // compressed, then encrypted
}
```

### Facade

```go
// Provide one simple entry point over a set of subsystems.
type OrderFacade struct {
	inventory    InventoryService
	payment      PaymentService
	shipping     ShippingService
	notification NotificationService
}

func NewOrderFacade(inv InventoryService, pay PaymentService, ship ShippingService, notif NotificationService) *OrderFacade {
	return &OrderFacade{inventory: inv, payment: pay, shipping: ship, notification: notif}
}

func (f *OrderFacade) PlaceOrder(ctx context.Context, order OrderRequest) (OrderResult, error) {
	available, err := f.inventory.CheckAvailability(ctx, order.Items)
	if err != nil {
		return OrderResult{}, fmt.Errorf("check availability: %w", err)
	}
	if !available {
		return OrderResult{}, ErrItemsUnavailable
	}

	reservation, err := f.inventory.Reserve(ctx, order.Items)
	if err != nil {
		return OrderResult{}, fmt.Errorf("reserve items: %w", err)
	}

	if _, err := f.payment.Charge(ctx, order.Total, order.PaymentMethod); err != nil {
		_ = f.inventory.CancelReservation(ctx, reservation.ID)
		return OrderResult{}, fmt.Errorf("charge payment: %w", err)
	}

	if err := f.inventory.ConfirmReservation(ctx, reservation.ID); err != nil {
		return OrderResult{}, fmt.Errorf("confirm reservation: %w", err)
	}

	shipment, err := f.shipping.CreateShipment(ctx, order)
	if err != nil {
		return OrderResult{}, fmt.Errorf("create shipment: %w", err)
	}

	if err := f.notification.SendOrderConfirmation(ctx, order, shipment); err != nil {
		return OrderResult{}, fmt.Errorf("send confirmation: %w", err)
	}

	return OrderResult{Success: true, OrderID: order.ID, ShipmentID: shipment.ID}, nil
}
```

### Repository

```go
// Mediates between the domain and data-mapping layers.
type Repository[T any, ID comparable] interface {
	FindByID(ctx context.Context, id ID) (*T, error)
	FindAll(ctx context.Context) ([]T, error)
	Save(ctx context.Context, entity *T) error
	Delete(ctx context.Context, id ID) error
}

// The consumer-side interface adds only what it needs.
type UserRepository interface {
	Repository[User, UserID]
	FindByEmail(ctx context.Context, email Email) (*User, error)
	FindActiveUsers(ctx context.Context) ([]User, error)
}

type PostgresUserRepository struct{ db *sql.DB }

func NewPostgresUserRepository(db *sql.DB) *PostgresUserRepository {
	return &PostgresUserRepository{db: db}
}

func (r *PostgresUserRepository) FindByID(ctx context.Context, id UserID) (*User, error) {
	row := r.db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = $1", id.Value())
	u, err := scanUser(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find user %s: %w", id.Value(), err)
	}
	return u, nil
}

func (r *PostgresUserRepository) FindByEmail(ctx context.Context, email Email) (*User, error) {
	row := r.db.QueryRowContext(ctx, "SELECT * FROM users WHERE email = $1", email.String())
	u, err := scanUser(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find user by email: %w", err)
	}
	return u, nil
}

func (r *PostgresUserRepository) FindAll(ctx context.Context) ([]User, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT * FROM users")
	if err != nil {
		return nil, fmt.Errorf("query users: %w", err)
	}
	defer rows.Close()
	return scanUsers(rows)
}

func (r *PostgresUserRepository) Save(ctx context.Context, u *User) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO users (id, name, email) VALUES ($1, $2, $3)
		 ON CONFLICT (id) DO UPDATE SET name = $2, email = $3`,
		u.ID, u.Name, u.Email)
	if err != nil {
		return fmt.Errorf("save user: %w", err)
	}
	return nil
}

func (r *PostgresUserRepository) Delete(ctx context.Context, id UserID) error {
	if _, err := r.db.ExecContext(ctx, "DELETE FROM users WHERE id = $1", id.Value()); err != nil {
		return fmt.Errorf("delete user %s: %w", id.Value(), err)
	}
	return nil
}

func (r *PostgresUserRepository) FindActiveUsers(ctx context.Context) ([]User, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT * FROM users WHERE active = true")
	if err != nil {
		return nil, fmt.Errorf("query active users: %w", err)
	}
	defer rows.Close()
	return scanUsers(rows)
}
```

## Behavioral Patterns

### Strategy

```go
// A family of interchangeable algorithms behind one interface.
type PricingStrategy interface {
	Calculate(o Order) Money
}

type StandardPricing struct{}

func (StandardPricing) Calculate(o Order) Money {
	total := ZeroMoney()
	for _, it := range o.Items {
		total = total.Add(it.Price.Mul(it.Quantity))
	}
	return total
}

type MemberPricing struct{ discountPercent int }

func NewMemberPricing(discountPercent int) MemberPricing {
	return MemberPricing{discountPercent: discountPercent}
}

func (m MemberPricing) Calculate(o Order) Money {
	standard := StandardPricing{}.Calculate(o)
	return standard.MulFloat(1 - float64(m.discountPercent)/100)
}

type BulkPricing struct{}

func (BulkPricing) Calculate(o Order) Money {
	total := ZeroMoney()
	for _, it := range o.Items {
		unit := it.Price
		if it.Quantity >= 10 {
			unit = unit.MulFloat(0.9) // 10% bulk discount
		}
		total = total.Add(unit.Mul(it.Quantity))
	}
	return total
}

// Inject the chosen strategy.
type OrderService struct{ pricing PricingStrategy }

func NewOrderService(pricing PricingStrategy) *OrderService { return &OrderService{pricing: pricing} }

func (s *OrderService) Total(o Order) Money { return s.pricing.Calculate(o) }

// Usage
func example() {
	member := NewOrderService(NewMemberPricing(15))
	bulk := NewOrderService(BulkPricing{})
	_, _ = member, bulk
}
```

### Observer

```go
// A one-to-many dependency between objects.
type Observer[T any] interface {
	Update(event T)
}

type Subject[T any] interface {
	Subscribe(o Observer[T])
	Unsubscribe(o Observer[T])
	Notify(event T)
}

type EventEmitter[T any] struct {
	mu        sync.RWMutex
	observers map[Observer[T]]struct{}
}

func NewEventEmitter[T any]() *EventEmitter[T] {
	return &EventEmitter[T]{observers: make(map[Observer[T]]struct{})}
}

func (e *EventEmitter[T]) Subscribe(o Observer[T]) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.observers[o] = struct{}{}
}

func (e *EventEmitter[T]) Unsubscribe(o Observer[T]) {
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.observers, o)
}

func (e *EventEmitter[T]) Notify(event T) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	for o := range e.observers {
		o.Update(event)
	}
}

// Observers react only to the events they care about.
type InventoryObserver struct{}

func (InventoryObserver) Update(evt OrderEvent) {
	if evt.Type == OrderCreated {
		// update inventory
	}
}

type NotificationObserver struct{}

func (NotificationObserver) Update(evt OrderEvent) {
	if evt.Type == OrderShipped {
		// send shipping notification
	}
}
```

### Command

```go
// Encapsulate a request as an object, enabling undo/redo and queuing.
type Command interface {
	Execute(ctx context.Context) error
	Undo(ctx context.Context) error
}

type AddItemCommand struct {
	cart      *ShoppingCart
	productID string
	quantity  int
	prevQty   int
}

func NewAddItemCommand(cart *ShoppingCart, productID string, quantity int) *AddItemCommand {
	return &AddItemCommand{cart: cart, productID: productID, quantity: quantity}
}

func (c *AddItemCommand) Execute(ctx context.Context) error {
	c.prevQty = c.cart.Quantity(c.productID)
	c.cart.AddItem(c.productID, c.quantity)
	return nil
}

func (c *AddItemCommand) Undo(ctx context.Context) error {
	if c.prevQty == 0 {
		c.cart.RemoveItem(c.productID)
		return nil
	}
	c.cart.SetItemQuantity(c.productID, c.prevQty)
	return nil
}

type CommandHistory struct {
	history  []Command
	position int // index of last executed command; -1 when empty
}

func NewCommandHistory() *CommandHistory { return &CommandHistory{position: -1} }

func (h *CommandHistory) Execute(ctx context.Context, cmd Command) error {
	h.history = h.history[:h.position+1] // drop any redoable commands past the cursor
	if err := cmd.Execute(ctx); err != nil {
		return fmt.Errorf("execute command: %w", err)
	}
	h.history = append(h.history, cmd)
	h.position++
	return nil
}

func (h *CommandHistory) Undo(ctx context.Context) error {
	if h.position < 0 {
		return nil
	}
	if err := h.history[h.position].Undo(ctx); err != nil {
		return fmt.Errorf("undo command: %w", err)
	}
	h.position--
	return nil
}

func (h *CommandHistory) Redo(ctx context.Context) error {
	if h.position >= len(h.history)-1 {
		return nil
	}
	h.position++
	if err := h.history[h.position].Execute(ctx); err != nil {
		return fmt.Errorf("redo command: %w", err)
	}
	return nil
}
```

### State

```go
// Alter behavior when internal state changes.
type OrderState interface {
	Proceed(o *Order) error
	Cancel(o *Order) error
	Ship(o *Order) error
}

type PendingState struct{}

func (PendingState) Proceed(o *Order) error { o.setState(ConfirmedState{}); return nil }
func (PendingState) Cancel(o *Order) error  { o.setState(CancelledState{}); return nil }
func (PendingState) Ship(o *Order) error    { return errors.New("cannot ship pending order") }

type ConfirmedState struct{}

func (ConfirmedState) Proceed(o *Order) error { o.setState(ProcessingState{}); return nil }
func (ConfirmedState) Cancel(o *Order) error  { o.setState(CancelledState{}); return nil }
func (ConfirmedState) Ship(o *Order) error {
	return errors.New("order must be processed before shipping")
}

type ProcessingState struct{}

func (ProcessingState) Proceed(o *Order) error {
	return errors.New("use Ship to proceed from processing")
}
func (ProcessingState) Cancel(o *Order) error { return errors.New("cannot cancel order in processing") }
func (ProcessingState) Ship(o *Order) error   { o.setState(ShippedState{}); return nil }

type Order struct{ state OrderState }

func NewOrder() *Order { return &Order{state: PendingState{}} }

func (o *Order) setState(s OrderState) { o.state = s }

func (o *Order) Proceed() error { return o.state.Proceed(o) }
func (o *Order) Cancel() error  { return o.state.Cancel(o) }
func (o *Order) Ship() error    { return o.state.Ship(o) }
```

## Pattern Selection Guide

| Need | Pattern | Example |
|------|---------|---------|
| Create objects without specifying type | Factory Method | Payment processor creation |
| Create families of related objects | Abstract Factory | UI component libraries |
| Complex object construction | Builder | SQL query builder |
| Single instance with global access | Singleton | Configuration manager |
| Convert incompatible interfaces | Adapter | Legacy system integration |
| Add behavior dynamically | Decorator | Logging, caching, encryption |
| Simplify complex subsystem | Facade | Order processing workflow |
| Persistence abstraction | Repository | Data access layer |
| Interchangeable algorithms | Strategy | Pricing, sorting, validation |
| Notify on state changes | Observer | Event-driven systems |
| Encapsulate operations | Command | Undo/redo, task queues |
| Behavior varies by state | State | Workflow, order status |
