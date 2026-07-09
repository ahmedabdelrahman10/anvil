---
name: builder-pattern
description: Builder pattern for complex object construction
category: architecture/design-patterns/creational
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Builder Pattern

## Overview

The Builder pattern separates the construction of a complex object from
its representation, allowing the same construction process to create
different representations.

## Problem

```go
// ❌ Constructor with many parameters
func NewEmail(
	to, from, subject, body string,
	cc, bcc []string,
	replyTo string,
	attachments []Attachment,
	priority string,
	readReceipt bool,
	headers map[string]string,
) *Email {
	// Hard to read, easy to mix up parameters.
	return &Email{ /* ... */ }
}

// Usage — confusing positional arguments
email := NewEmail(
	"user@example.com",
	"noreply@company.com",
	"Welcome!",
	"Hello...",
	nil,    // cc
	nil,    // bcc
	"",     // replyTo
	nil,    // attachments
	"high", // priority
	true,   // readReceipt
	nil,    // headers
)
```

## Solution: Functional Options

```go
// ✅ Functional options — the idiomatic Go "builder"
type Email struct {
	to          string
	from        string
	subject     string
	body        string
	cc          []string
	bcc         []string
	replyTo     string
	attachments []Attachment
	priority    string
	readReceipt bool
	headers     map[string]string
}

// Option mutates an Email under construction.
type Option func(*Email)

func WithCC(addresses ...string) Option {
	return func(e *Email) { e.cc = append(e.cc, addresses...) }
}

func WithBCC(addresses ...string) Option {
	return func(e *Email) { e.bcc = append(e.bcc, addresses...) }
}

func WithReplyTo(address string) Option {
	return func(e *Email) { e.replyTo = address }
}

func WithAttachment(a Attachment) Option {
	return func(e *Email) { e.attachments = append(e.attachments, a) }
}

func WithPriority(level string) Option {
	return func(e *Email) { e.priority = level }
}

func WithReadReceipt() Option {
	return func(e *Email) { e.readReceipt = true }
}

func WithHeader(name, value string) Option {
	return func(e *Email) {
		if e.headers == nil {
			e.headers = make(map[string]string)
		}
		e.headers[name] = value
	}
}

// NewEmail takes the required fields positionally and the rest as options,
// validating once before returning.
func NewEmail(to, from, subject, body string, opts ...Option) (*Email, error) {
	switch {
	case to == "":
		return nil, errors.New("to address is required")
	case from == "":
		return nil, errors.New("from address is required")
	case subject == "":
		return nil, errors.New("subject is required")
	case body == "":
		return nil, errors.New("body is required")
	}

	e := &Email{to: to, from: from, subject: subject, body: body}
	for _, opt := range opts {
		opt(e)
	}
	return e, nil
}

// Usage — clear and readable
email, err := NewEmail(
	"user@example.com",
	"noreply@company.com",
	"Welcome!",
	"Hello, welcome to our platform!",
	WithPriority("high"),
	WithReadReceipt(),
	WithAttachment(Attachment{Filename: "guide.pdf", Content: pdfBytes}),
)
if err != nil {
	return fmt.Errorf("build email: %w", err)
}
```

## Fluent Builder

```go
// A classic fluent builder is also possible when a step-by-step API reads
// better; accumulate fields, then validate in Build.
type EmailBuilder struct {
	email Email
}

func NewEmailBuilder() *EmailBuilder {
	return &EmailBuilder{}
}

func (b *EmailBuilder) To(address string) *EmailBuilder {
	b.email.to = address
	return b
}

func (b *EmailBuilder) From(address string) *EmailBuilder {
	b.email.from = address
	return b
}

func (b *EmailBuilder) Subject(subject string) *EmailBuilder {
	b.email.subject = subject
	return b
}

func (b *EmailBuilder) Body(content string) *EmailBuilder {
	b.email.body = content
	return b
}

func (b *EmailBuilder) CC(addresses ...string) *EmailBuilder {
	b.email.cc = append(b.email.cc, addresses...)
	return b
}

func (b *EmailBuilder) Priority(level string) *EmailBuilder {
	b.email.priority = level
	return b
}

func (b *EmailBuilder) Attach(a Attachment) *EmailBuilder {
	b.email.attachments = append(b.email.attachments, a)
	return b
}

// Build validates the accumulated fields and returns the Email.
func (b *EmailBuilder) Build() (*Email, error) {
	switch {
	case b.email.to == "":
		return nil, errors.New("to address is required")
	case b.email.from == "":
		return nil, errors.New("from address is required")
	case b.email.subject == "":
		return nil, errors.New("subject is required")
	case b.email.body == "":
		return nil, errors.New("body is required")
	}
	out := b.email
	return &out, nil
}

// Usage — clear and readable
email, err := NewEmailBuilder().
	To("user@example.com").
	From("noreply@company.com").
	Subject("Welcome!").
	Body("Hello, welcome to our platform!").
	Priority("high").
	Attach(Attachment{Filename: "guide.pdf", Content: pdfBytes}).
	Build()
if err != nil {
	return fmt.Errorf("build email: %w", err)
}
```

## Builder with Director

```go
// A "director" in Go is just a function that encapsulates a common
// construction sequence over the options above.
func WelcomeEmail(user User) (*Email, error) {
	return NewEmail(
		user.Email,
		"welcome@company.com",
		"Welcome to Our Platform!",
		welcomeTemplate(user),
		WithPriority("normal"),
	)
}

func PasswordResetEmail(user User, resetToken string) (*Email, error) {
	return NewEmail(
		user.Email,
		"security@company.com",
		"Password Reset Request",
		passwordResetTemplate(user, resetToken),
		WithPriority("high"),
		WithHeader("X-Priority", "1"),
	)
}

func OrderConfirmationEmail(user User, order Order) (*Email, error) {
	return NewEmail(
		user.Email,
		"orders@company.com",
		fmt.Sprintf("Order Confirmation #%s", order.ID),
		orderTemplate(order),
		WithAttachment(invoicePDF(order)),
	)
}

func welcomeTemplate(user User) string {
	return fmt.Sprintf("Hello %s, welcome to our platform!", user.Name)
}

func passwordResetTemplate(user User, token string) string {
	return fmt.Sprintf("Click here to reset: %s?token=%s", resetURL, token)
}

func orderTemplate(order Order) string {
	return fmt.Sprintf("Thank you for your order #%s", order.ID)
}

func invoicePDF(order Order) Attachment {
	// Generate PDF.
	return Attachment{Filename: fmt.Sprintf("invoice-%s.pdf", order.ID), Content: nil}
}

// Usage
welcome, err := WelcomeEmail(user)
if err != nil {
	return fmt.Errorf("welcome email: %w", err)
}
reset, err := PasswordResetEmail(user, token)
if err != nil {
	return fmt.Errorf("reset email: %w", err)
}
```

## Builder for Complex Objects

```go
// Query builder — assembles a parameterized SQL statement.
type QueryBuilder struct {
	columns []string
	table   string
	wheres  []whereClause
	joins   []joinClause
	orders  []orderClause
	limit   *int
	offset  *int
}

type whereClause struct {
	condition string
	params    []any
	or        bool
}

type joinClause struct {
	kind      string
	table     string
	condition string
}

type orderClause struct {
	column    string
	direction string
}

func NewQueryBuilder() *QueryBuilder {
	return &QueryBuilder{columns: []string{"*"}}
}

func (q *QueryBuilder) Select(columns ...string) *QueryBuilder {
	q.columns = columns
	return q
}

func (q *QueryBuilder) From(table string) *QueryBuilder {
	q.table = table
	return q
}

func (q *QueryBuilder) Where(condition string, params ...any) *QueryBuilder {
	q.wheres = append(q.wheres, whereClause{condition: condition, params: params})
	return q
}

func (q *QueryBuilder) AndWhere(condition string, params ...any) *QueryBuilder {
	return q.Where(condition, params...)
}

func (q *QueryBuilder) OrWhere(condition string, params ...any) *QueryBuilder {
	q.wheres = append(q.wheres, whereClause{condition: condition, params: params, or: true})
	return q
}

func (q *QueryBuilder) Join(table, condition string) *QueryBuilder {
	q.joins = append(q.joins, joinClause{kind: "INNER", table: table, condition: condition})
	return q
}

func (q *QueryBuilder) LeftJoin(table, condition string) *QueryBuilder {
	q.joins = append(q.joins, joinClause{kind: "LEFT", table: table, condition: condition})
	return q
}

func (q *QueryBuilder) OrderBy(column, direction string) *QueryBuilder {
	q.orders = append(q.orders, orderClause{column: column, direction: direction})
	return q
}

func (q *QueryBuilder) Limit(count int) *QueryBuilder {
	q.limit = &count
	return q
}

func (q *QueryBuilder) Offset(count int) *QueryBuilder {
	q.offset = &count
	return q
}

// ToSQL renders the statement and its ordered parameters.
func (q *QueryBuilder) ToSQL() (string, []any) {
	var sb strings.Builder
	params := make([]any, 0)
	paramIndex := 1

	fmt.Fprintf(&sb, "SELECT %s", strings.Join(q.columns, ", "))
	fmt.Fprintf(&sb, " FROM %s", q.table)

	for _, j := range q.joins {
		fmt.Fprintf(&sb, " %s JOIN %s ON %s", j.kind, j.table, j.condition)
	}

	for i, w := range q.wheres {
		prefix := "AND"
		switch {
		case i == 0:
			prefix = "WHERE"
		case w.or:
			prefix = "OR"
		}
		condition := replacePlaceholders(w.condition, &paramIndex)
		params = append(params, w.params...)
		fmt.Fprintf(&sb, " %s %s", prefix, condition)
	}

	if len(q.orders) > 0 {
		parts := make([]string, 0, len(q.orders))
		for _, o := range q.orders {
			parts = append(parts, fmt.Sprintf("%s %s", o.column, o.direction))
		}
		fmt.Fprintf(&sb, " ORDER BY %s", strings.Join(parts, ", "))
	}

	if q.limit != nil {
		fmt.Fprintf(&sb, " LIMIT %d", *q.limit)
	}
	if q.offset != nil {
		fmt.Fprintf(&sb, " OFFSET %d", *q.offset)
	}

	return sb.String(), params
}

// Execute runs the built query against db.
func (q *QueryBuilder) Execute(ctx context.Context, db *sql.DB) (*sql.Rows, error) {
	query, params := q.ToSQL()
	rows, err := db.QueryContext(ctx, query, params...)
	if err != nil {
		return nil, fmt.Errorf("execute query: %w", err)
	}
	return rows, nil
}

// replacePlaceholders rewrites each "?" to a positional "$n" placeholder.
func replacePlaceholders(condition string, index *int) string {
	var sb strings.Builder
	for _, r := range condition {
		if r == '?' {
			fmt.Fprintf(&sb, "$%d", *index)
			*index++
			continue
		}
		sb.WriteRune(r)
	}
	return sb.String()
}

// Usage
query, params := NewQueryBuilder().
	Select("users.id", "users.name", "orders.total").
	From("users").
	LeftJoin("orders", "orders.user_id = users.id").
	Where("users.active = ?", true).
	AndWhere("users.created_at > ?", startOfYear).
	OrderBy("users.name", "ASC").
	Limit(10).
	Offset(20).
	ToSQL()
```

## Builder for HTTP Requests

```go
type HTTPRequestBuilder struct {
	method     string
	url        string
	headers    map[string]string
	body       io.Reader
	timeout    time.Duration
	retries    int
	retryDelay time.Duration
	err        error // deferred until Send, so the chain stays fluent
}

func NewHTTPRequestBuilder() *HTTPRequestBuilder {
	return &HTTPRequestBuilder{
		method:  http.MethodGet,
		headers: make(map[string]string),
		timeout: 30 * time.Second,
	}
}

func (b *HTTPRequestBuilder) URL(url string) *HTTPRequestBuilder {
	b.url = url
	return b
}

func (b *HTTPRequestBuilder) Method(method string) *HTTPRequestBuilder {
	b.method = method
	return b
}

func (b *HTTPRequestBuilder) Get(url string) *HTTPRequestBuilder {
	return b.Method(http.MethodGet).URL(url)
}

func (b *HTTPRequestBuilder) Post(url string) *HTTPRequestBuilder {
	return b.Method(http.MethodPost).URL(url)
}

func (b *HTTPRequestBuilder) Put(url string) *HTTPRequestBuilder {
	return b.Method(http.MethodPut).URL(url)
}

func (b *HTTPRequestBuilder) Delete(url string) *HTTPRequestBuilder {
	return b.Method(http.MethodDelete).URL(url)
}

func (b *HTTPRequestBuilder) Header(name, value string) *HTTPRequestBuilder {
	b.headers[name] = value
	return b
}

func (b *HTTPRequestBuilder) BearerToken(token string) *HTTPRequestBuilder {
	return b.Header("Authorization", "Bearer "+token)
}

func (b *HTTPRequestBuilder) ContentType(contentType string) *HTTPRequestBuilder {
	return b.Header("Content-Type", contentType)
}

func (b *HTTPRequestBuilder) JSON(data any) *HTTPRequestBuilder {
	encoded, err := json.Marshal(data)
	if err != nil {
		b.err = fmt.Errorf("marshal json body: %w", err)
		return b
	}
	b.body = bytes.NewReader(encoded)
	return b.ContentType("application/json")
}

func (b *HTTPRequestBuilder) Timeout(d time.Duration) *HTTPRequestBuilder {
	b.timeout = d
	return b
}

func (b *HTTPRequestBuilder) Retry(count int, delay time.Duration) *HTTPRequestBuilder {
	b.retries = count
	b.retryDelay = delay
	return b
}

// Send builds and issues the request, surfacing any error accumulated by the
// chain. ctx bounds the whole call; the builder never stores it.
func (b *HTTPRequestBuilder) Send(ctx context.Context, client *http.Client) (*http.Response, error) {
	if b.err != nil {
		return nil, b.err
	}
	if b.url == "" {
		return nil, errors.New("url is required")
	}

	ctx, cancel := context.WithTimeout(ctx, b.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, b.method, b.url, b.body)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	for name, value := range b.headers {
		req.Header.Set(name, value)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	return resp, nil
}

// Usage
resp, err := NewHTTPRequestBuilder().
	Post("https://api.example.com/users").
	BearerToken(token).
	JSON(map[string]string{"name": "John", "email": "john@example.com"}).
	Timeout(5 * time.Second).
	Retry(3, time.Second).
	Send(ctx, http.DefaultClient)
if err != nil {
	return fmt.Errorf("send request: %w", err)
}
defer resp.Body.Close()
```

## Step Builder (Type-Safe)

```go
// Enforce required fields at compile time: each stage returns the next
// stage's type, so the compiler requires the mandatory calls in order.
type emailStepData struct {
	to, from, subject, body string
	cc, bcc                 []string
	priority                string
}

// Step 1: an empty builder can only set To.
type EmailStepStart struct {
	data emailStepData
}

func NewStepEmailBuilder() *EmailStepStart {
	return &EmailStepStart{}
}

func (b *EmailStepStart) To(address string) *EmailStepTo {
	b.data.to = address
	return &EmailStepTo{data: b.data}
}

// Step 2: after To, only From is available.
type EmailStepTo struct {
	data emailStepData
}

func (b *EmailStepTo) From(address string) *EmailStepFrom {
	b.data.from = address
	return &EmailStepFrom{data: b.data}
}

// Step 3: after From, only Subject is available.
type EmailStepFrom struct {
	data emailStepData
}

func (b *EmailStepFrom) Subject(subject string) *EmailStepSubject {
	b.data.subject = subject
	return &EmailStepSubject{data: b.data}
}

// Step 4: after Subject, only Body is available.
type EmailStepSubject struct {
	data emailStepData
}

func (b *EmailStepSubject) Body(content string) *EmailStepComplete {
	b.data.body = content
	return &EmailStepComplete{data: b.data}
}

// Final step: optional fields plus Build.
type EmailStepComplete struct {
	data emailStepData
}

func (b *EmailStepComplete) CC(addresses ...string) *EmailStepComplete {
	b.data.cc = append(b.data.cc, addresses...)
	return b
}

func (b *EmailStepComplete) BCC(addresses ...string) *EmailStepComplete {
	b.data.bcc = append(b.data.bcc, addresses...)
	return b
}

func (b *EmailStepComplete) Priority(level string) *EmailStepComplete {
	b.data.priority = level
	return b
}

func (b *EmailStepComplete) Build() *Email {
	return &Email{
		to:       b.data.to,
		from:     b.data.from,
		subject:  b.data.subject,
		body:     b.data.body,
		cc:       b.data.cc,
		bcc:      b.data.bcc,
		priority: b.data.priority,
	}
}

// Usage — compile-time enforcement of required fields
email := NewStepEmailBuilder().
	To("user@example.com"). // Must call To() first
	From("noreply@co.com"). // Then From()
	Subject("Hello").       // Then Subject()
	Body("Content").        // Then Body()
	Priority("high").       // Optional
	Build()
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Readability | Clear, fluent API |
| Flexibility | Optional parameters without constructor overloads |
| Validation | Centralized validation in build() |
| Immutability | Can create immutable objects |
| Testability | Easy to create test fixtures |
