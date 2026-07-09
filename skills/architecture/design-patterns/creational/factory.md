---
name: factory-pattern
description: Factory patterns for object creation
category: architecture/design-patterns/creational
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Factory Pattern

## Overview

Factory patterns encapsulate object creation logic, providing flexibility
in instantiation without exposing creation logic to the client.

## Factory Method Pattern

### Problem
```go
// ❌ Client wires every dependency into the branch itself
type OrderService struct {
	smtpHost     string
	smtpPort     int
	smtpUser     string
	smtpPass     string
	twilioSID    string
	twilioToken  string
	twilioNumber string
	firebaseKey  string
}

func (s *OrderService) createNotification(kind string) (Notification, error) {
	switch kind {
	case "email":
		return NewEmailNotification(s.smtpHost, s.smtpPort, s.smtpUser, s.smtpPass), nil
	case "sms":
		return NewSMSNotification(s.twilioSID, s.twilioToken, s.twilioNumber), nil
	case "push":
		return NewPushNotification(s.firebaseKey), nil
	default:
		return nil, fmt.Errorf("unknown notification type: %q", kind)
	}
}
```

### Solution
```go
// ✅ Factory function type — the Go form of a "factory method"
type Notification interface {
	Send(ctx context.Context, message, recipient string) error
}

// NotificationFactory constructs a Notification on demand.
type NotificationFactory func() Notification

// Notify builds a notification via the factory and sends it.
func Notify(ctx context.Context, factory NotificationFactory, message, recipient string) error {
	n := factory()
	if err := n.Send(ctx, message, recipient); err != nil {
		return fmt.Errorf("send notification: %w", err)
	}
	return nil
}

// Concrete factories are just constructors that return the interface.
func NewEmailFactory(cfg EmailConfig) NotificationFactory {
	return func() Notification { return NewEmailNotification(cfg) }
}

func NewSMSFactory(cfg SMSConfig) NotificationFactory {
	return func() Notification { return NewSMSNotification(cfg) }
}

// Usage
factory := NewEmailFactory(emailConfig)
if err := Notify(ctx, factory, "Order confirmed", "user@example.com"); err != nil {
	return fmt.Errorf("notify: %w", err)
}
```

## Simple Factory

```go
// Simple factory — not a GoF pattern, but common and effective in Go.
type NotificationType int

const (
	NotificationEmail NotificationType = iota
	NotificationSMS
	NotificationPush
)

// SimpleNotificationFactory holds the config each notifier needs and builds
// them by type. Prefer a switch over reflection.
type SimpleNotificationFactory struct {
	email EmailConfig
	sms   SMSConfig
	push  PushConfig
}

func NewSimpleNotificationFactory(email EmailConfig, sms SMSConfig, push PushConfig) *SimpleNotificationFactory {
	return &SimpleNotificationFactory{email: email, sms: sms, push: push}
}

func (f *SimpleNotificationFactory) Create(kind NotificationType) (Notification, error) {
	switch kind {
	case NotificationEmail:
		return NewEmailNotification(f.email), nil
	case NotificationSMS:
		return NewSMSNotification(f.sms), nil
	case NotificationPush:
		return NewPushNotification(f.push), nil
	default:
		return nil, fmt.Errorf("unknown notification type: %d", kind)
	}
}

// Usage
factory := NewSimpleNotificationFactory(emailConfig, smsConfig, pushConfig)
notification, err := factory.Create(NotificationEmail)
if err != nil {
	return fmt.Errorf("create notification: %w", err)
}
if err := notification.Send(ctx, "Hello", "user@example.com"); err != nil {
	return fmt.Errorf("send: %w", err)
}
```

## Abstract Factory Pattern

### When You Need Families of Related Objects

```go
// Abstract factory for UI components — a family of related widgets.
type Button interface {
	Render() string
	OnClick(handler func())
}

type Input interface {
	Render() string
	Value() string
}

type Modal interface {
	Render() string
	Open()
	Close()
}

// UIComponentFactory builds a whole family of widgets.
type UIComponentFactory interface {
	NewButton(label string) Button
	NewInput(placeholder string) Input
	NewModal(title string) Modal
}

// Material Design implementation
type MaterialButton struct {
	label string
}

func NewMaterialButton(label string) *MaterialButton {
	return &MaterialButton{label: label}
}

func (b *MaterialButton) Render() string {
	return fmt.Sprintf(`<button class="mdc-button">%s</button>`, b.label)
}

func (b *MaterialButton) OnClick(handler func()) { /* ... */ }

type MaterialInput struct {
	placeholder string
}

func NewMaterialInput(placeholder string) *MaterialInput {
	return &MaterialInput{placeholder: placeholder}
}

func (i *MaterialInput) Render() string {
	return fmt.Sprintf(`<input class="mdc-text-field" placeholder="%s">`, i.placeholder)
}

func (i *MaterialInput) Value() string { return "" }

// MaterialUIFactory returns Material-flavoured widgets.
type MaterialUIFactory struct{}

func (MaterialUIFactory) NewButton(label string) Button     { return NewMaterialButton(label) }
func (MaterialUIFactory) NewInput(placeholder string) Input { return NewMaterialInput(placeholder) }
func (MaterialUIFactory) NewModal(title string) Modal       { return NewMaterialModal(title) }

// Bootstrap implementation
type BootstrapButton struct {
	label string
}

func NewBootstrapButton(label string) *BootstrapButton {
	return &BootstrapButton{label: label}
}

func (b *BootstrapButton) Render() string {
	return fmt.Sprintf(`<button class="btn btn-primary">%s</button>`, b.label)
}

func (b *BootstrapButton) OnClick(handler func()) { /* ... */ }

// BootstrapUIFactory returns Bootstrap-flavoured widgets.
type BootstrapUIFactory struct{}

func (BootstrapUIFactory) NewButton(label string) Button     { return NewBootstrapButton(label) }
func (BootstrapUIFactory) NewInput(placeholder string) Input { return NewBootstrapInput(placeholder) }
func (BootstrapUIFactory) NewModal(title string) Modal       { return NewBootstrapModal(title) }

// Usage — the application doesn't know which UI framework is used.
type LoginForm struct {
	ui UIComponentFactory
}

func NewLoginForm(ui UIComponentFactory) *LoginForm {
	return &LoginForm{ui: ui}
}

func (f *LoginForm) Render() string {
	email := f.ui.NewInput("Email")
	password := f.ui.NewInput("Password")
	submit := f.ui.NewButton("Login")

	return fmt.Sprintf(`
      <form>
        %s
        %s
        %s
      </form>
    `, email.Render(), password.Render(), submit.Render())
}

// Switch the whole UI family by swapping the factory.
materialForm := NewLoginForm(MaterialUIFactory{})
bootstrapForm := NewLoginForm(BootstrapUIFactory{})
```

## Factory with Registry

```go
// Dynamic registration of factories — plugin-style wiring.
type PaymentGatewayRegistry struct {
	mu        sync.RWMutex
	factories map[string]func() PaymentGateway
}

func NewPaymentGatewayRegistry() *PaymentGatewayRegistry {
	return &PaymentGatewayRegistry{factories: make(map[string]func() PaymentGateway)}
}

func (r *PaymentGatewayRegistry) Register(name string, factory func() PaymentGateway) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.factories[name] = factory
}

func (r *PaymentGatewayRegistry) Create(name string) (PaymentGateway, error) {
	r.mu.RLock()
	factory, ok := r.factories[name]
	r.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("unknown payment gateway: %q", name)
	}
	return factory(), nil
}

func (r *PaymentGatewayRegistry) AvailableTypes() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	types := make([]string, 0, len(r.factories))
	for name := range r.factories {
		types = append(types, name)
	}
	return types
}

// Registration at application startup
registry := NewPaymentGatewayRegistry()

registry.Register("stripe", func() PaymentGateway { return NewStripeGateway(stripeConfig) })
registry.Register("paypal", func() PaymentGateway { return NewPayPalGateway(paypalConfig) })
registry.Register("braintree", func() PaymentGateway { return NewBraintreeGateway(braintreeConfig) })

// Plugin-style registration
if os.Getenv("ENABLE_CRYPTO_PAYMENTS") != "" {
	registry.Register("bitcoin", func() PaymentGateway { return NewBitcoinGateway(bitcoinConfig) })
}

// Usage
gateway, err := registry.Create("stripe")
if err != nil {
	return fmt.Errorf("create gateway: %w", err)
}
if err := gateway.Charge(ctx, amount); err != nil {
	return fmt.Errorf("charge: %w", err)
}
```

## Factory in Domain-Driven Design

```go
// ErrProductNotAvailable is returned when an item cannot be reserved.
var ErrProductNotAvailable = errors.New("product not available")

// OrderFactory encapsulates the complex creation rules for an Order.
type OrderFactory struct {
	ids       IDGenerator
	pricing   PricingService
	inventory InventoryService
}

func NewOrderFactory(ids IDGenerator, pricing PricingService, inventory InventoryService) *OrderFactory {
	return &OrderFactory{ids: ids, pricing: pricing, inventory: inventory}
}

func (f *OrderFactory) Create(ctx context.Context, params CreateOrderParams) (*Order, error) {
	// Validate items are available.
	for _, item := range params.Items {
		available, err := f.inventory.CheckAvailability(ctx, item.ProductID, item.Quantity)
		if err != nil {
			return nil, fmt.Errorf("check availability for %s: %w", item.ProductID, err)
		}
		if !available {
			return nil, fmt.Errorf("%w: %s", ErrProductNotAvailable, item.ProductID)
		}
	}

	// Calculate prices.
	orderItems := make([]OrderItem, 0, len(params.Items))
	for _, item := range params.Items {
		price, err := f.pricing.Price(ctx, item.ProductID, params.CustomerID)
		if err != nil {
			return nil, fmt.Errorf("price %s: %w", item.ProductID, err)
		}
		orderItems = append(orderItems, NewOrderItem(item.ProductID, item.Quantity, price))
	}

	// Create order with a generated ID.
	return NewOrder(f.ids.Generate(), params.CustomerID, orderItems, params.ShippingAddress), nil
}

// Reconstitute rebuilds an Order from persistence (no validation needed).
func (f *OrderFactory) Reconstitute(data OrderData) *Order {
	items := make([]OrderItem, 0, len(data.Items))
	for _, item := range data.Items {
		items = append(items, ReconstituteOrderItem(
			item.ProductID,
			item.Quantity,
			NewMoney(item.Price, item.Currency),
		))
	}
	return ReconstituteOrder(data.ID, data.CustomerID, items, data.Status, data.CreatedAt)
}
```

## Static Factory Methods

```go
// Package-level constructor functions with clear intent. Money is an
// immutable value stored as integer minor units (cents).
type Money struct {
	amount   int64 // minor units, e.g. cents
	currency string
}

var moneyPattern = regexp.MustCompile(`^([A-Z]{3})\s*(\d+(?:\.\d{2})?)$`)

// ZeroMoney returns a zero amount in the given currency.
func ZeroMoney(currency string) Money {
	return Money{amount: 0, currency: currency}
}

// MoneyFromCents builds Money from an integer number of cents.
func MoneyFromCents(cents int64, currency string) Money {
	return Money{amount: cents, currency: currency}
}

// USD builds a US-dollar amount from a decimal value.
func USD(amount float64) Money {
	return Money{amount: int64(math.Round(amount * 100)), currency: "USD"}
}

// EUR builds a euro amount from a decimal value.
func EUR(amount float64) Money {
	return Money{amount: int64(math.Round(amount * 100)), currency: "EUR"}
}

// ParseMoney parses strings like "USD 49.99".
func ParseMoney(value string) (Money, error) {
	m := moneyPattern.FindStringSubmatch(value)
	if m == nil {
		return Money{}, fmt.Errorf("invalid money format: %q", value)
	}
	amount, err := strconv.ParseFloat(m[2], 64)
	if err != nil {
		return Money{}, fmt.Errorf("parse amount %q: %w", m[2], err)
	}
	return Money{amount: int64(math.Round(amount * 100)), currency: m[1]}, nil
}

// Usage — clear intent
price := USD(99.99)
zero := ZeroMoney("EUR")
fromDB := MoneyFromCents(9999, "USD")
parsed, err := ParseMoney("USD 49.99")
if err != nil {
	return fmt.Errorf("parse money: %w", err)
}
```

## When to Use

| Pattern | Use Case |
|---------|----------|
| Simple Factory | Single type hierarchy, central creation |
| Factory Method | Caller decides which implementation to create |
| Abstract Factory | Families of related objects |
| Registry | Plugin architecture, runtime registration |

## Benefits

- Decouples creation from usage
- Centralizes complex creation logic
- Enables testing with fake factories
- Supports Open/Closed principle
