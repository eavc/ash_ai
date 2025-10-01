# MCP OAuth Configuration

Ash AI ships an IdP-agnostic MCP router that supports OAuth 2.1 bearer tokens from any compliant identity provider. The router emits structured tool responses and resource metadata required by the 2025-06-18 MCP specification, with comprehensive telemetry for observability and audit trails. This guide walks through the configuration and explains the moving parts.

## Prerequisites

1. **AshAuthentication** must be installed if using default JWT verification
2. **Environment variables** (see Configuration section below)
3. **Phoenix pipeline** with `AshAi.Mcp.Auth.OAuthBearerPlug`

## Quick Start

Generate MCP scaffolding with OAuth support:

```bash
# With OIDC/JWKS (Auth0, Okta, etc.)
mix ash_ai.gen.mcp \
  --user MyApp.Accounts.User \
  --issuer "https://my-tenant.auth0.com" \
  --audience "https://api.example.com/mcp"

# With default AshAuthentication JWT
mix ash_ai.gen.mcp --user MyApp.Accounts.User

# With wrappers for cleaner organization (recommended)
mix ash_ai.gen.mcp \
  --user MyApp.Accounts.User \
  --wrappers \
  --issuer "https://my-tenant.auth0.com" \
  --audience "https://api.example.com/mcp"
```

The `--wrappers` option creates `MyAppWeb.McpOAuthPlug` and `MyAppWeb.McpRouter` modules so you can keep
environment lookups and Phoenix wiring in dedicated, testable modules. The `--issuer` and `--audience`
flags document expected environment variable values in the generated wrapper's moduledoc.

## Configuration

### Environment Variables

All setups require:

```bash
MCP_PUBLIC_URL=https://your-app.com
MCP_REQUIRED_SCOPES=mcp:access
# Optional: override derived authorization servers or add support metadata
MCP_AUTHORIZATION_SERVERS=https://issuer-a.example/.well-known/oauth-authorization-server,https://issuer-b.example/.well-known/oauth-authorization-server
MCP_WWW_AUTH_EXTRAS={"error_contact":"mailto:security@example.com"}
```

When using OIDC/JWKS verification (with `--issuer` flag):

```bash
MCP_ISSUER=https://my-tenant.auth0.com
MCP_RESOURCE_INDICATOR=https://your-app.com/mcp
```

### Phoenix Pipeline

The generator adds an `:mcp` pipeline to your router. Example with OIDC/JWKS:

```elixir
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
    verifier_context: [
    issuer: System.fetch_env!("MCP_ISSUER"),
    resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
    actor_resource: MyApp.Accounts.User,
    algorithms: ["RS256"]
    ],
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    resource_path: "/mcp",
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end
```

The plug validates bearer tokens, enforces RFC 8707 resource indicators, and assigns the decoded actor/tenant for downstream tool execution.

### Router Forward

The generator forwards `/mcp` to the router with required options:

```elixir
scope "/mcp" do
  pipe_through :mcp

  forward "/", AshAi.Mcp.Router,
    otp_app: :my_app,
    resource_path: "/mcp",
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    authorization_servers: ["https://my-tenant.auth0.com/.well-known/oauth-authorization-server"],
    resource_signing_algorithms_supported: ["RS256"],
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    oauth_required?: true,
    tools: [
      # :tool1,
      # :tool2
    ]
end
```

Key behaviors:

- The router rejects requests missing `MCP-Protocol-Version: 2025-06-18` with a JSON-RPC error (`_meta.reason = "missing_protocol_version"`)
- `/.well-known/oauth-protected-resource` advertises the resource indicator, authorization server URIs, supported scopes, and signing algorithms
- `tools/list` and `tools/call` responses include structured content, `_meta` timing, optional resource links, and emit comprehensive telemetry (see [Telemetry](#telemetry) section)

### Wrapper Modules

When the generator runs with `--wrappers` it produces project-specific wrappers so your router stays
minimal:

```elixir
defmodule MyAppWeb.McpOAuthPlug do
  use AshAi.Mcp.PhoenixOAuthPlug,
    otp_app: :my_app,
    resource_path: "/mcp",
    required?: true,
    env: [
      public_base_url: "MCP_PUBLIC_URL",
      resource_indicator: "MCP_RESOURCE_INDICATOR",
      required_scopes: "MCP_REQUIRED_SCOPES",
      authorization_servers: "MCP_AUTHORIZATION_SERVERS",
      www_authenticate_params: "MCP_WWW_AUTH_EXTRAS"
    ],
    verifier_context: [
      actor_resource: MyApp.Accounts.User,
      issuer: {:env!, "MCP_ISSUER"},
      resource_indicator: {:env!, "MCP_RESOURCE_INDICATOR"}
    ],
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4
end

defmodule MyAppWeb.McpRouter do
  use AshAi.Mcp.PhoenixRouter,
    otp_app: :my_app,
    path: "/mcp",
    tools: [
      # :list_posts
    ],
    meta_builder: &__MODULE__.meta_builder/1,
    resource_link_builder: &__MODULE__.resource_links/3

  alias MyAppWeb.Router.Helpers, as: Routes

  def meta_builder(_context), do: %{}
  def resource_links(_tool, _data, _context), do: []
end
```

With wrappers your Phoenix router only needs:

```elixir
scope "/mcp" do
  pipe_through :mcp
  forward "/", MyAppWeb.McpRouter
end
```

### Multi-issuer Discovery

`AshAi.Mcp.Auth.ResourceMetadata` now derives `authorization_servers` when one or more issuers are
present in `verifier_context`. Provide a primary issuer or a list of tenant issuers and the
`.well-known/oauth-protected-resource` endpoint will advertise each corresponding
`/.well-known/oauth-authorization-server` URL automatically.

```elixir
forward "/", AshAi.Mcp.Router,
  otp_app: :my_app,
  resource_path: "/mcp",
  verifier_context: [
    issuer: "https://tenant-a.example",
    issuers: ["https://tenant-b.example", "https://tenant-c.example"]
  ]
```

## Provider Examples

### Auth0

```elixir
# Environment
MCP_ISSUER=https://my-tenant.auth0.com
MCP_RESOURCE_INDICATOR=https://api.example.com/mcp
MCP_PUBLIC_URL=https://api.example.com
MCP_REQUIRED_SCOPES=mcp:access

# Pipeline
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
    verifier_context: [
      issuer: System.fetch_env!("MCP_ISSUER"),
      resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
      actor_resource: MyApp.Accounts.User,
      algorithms: ["RS256"]
    ],
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end

# Router
forward "/", AshAi.Mcp.Router,
  otp_app: :my_app,
  resource_path: "/mcp",
  public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
  authorization_servers: ["https://my-tenant.auth0.com/.well-known/oauth-authorization-server"],
  resource_signing_algorithms_supported: ["RS256"],
  required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
  oauth_required?: true,
  tools: []
```

### Okta

```elixir
# Environment
MCP_ISSUER=https://dev-123456.okta.com/oauth2/default
MCP_RESOURCE_INDICATOR=https://api.example.com/mcp
MCP_PUBLIC_URL=https://api.example.com
MCP_REQUIRED_SCOPES=mcp:access

# Pipeline (same as Auth0)
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
    verifier_context: [
      issuer: System.fetch_env!("MCP_ISSUER"),
      resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
      actor_resource: MyApp.Accounts.User,
      algorithms: ["RS256"]
    ],
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end
```

### Azure AD (Microsoft Entra ID)

```elixir
# Environment
MCP_ISSUER=https://login.microsoftonline.com/{tenant-id}/v2.0
MCP_RESOURCE_INDICATOR=https://api.example.com/mcp
MCP_PUBLIC_URL=https://api.example.com
MCP_REQUIRED_SCOPES=mcp:access

# Pipeline (same as Auth0)
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
    verifier_context: [
      issuer: System.fetch_env!("MCP_ISSUER"),
      resource_indicator: System.fetch_env!("MCP_RESOURCE_INDICATOR"),
      actor_resource: MyApp.Accounts.User,
      algorithms: ["RS256"]
    ],
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end
```

### Custom AshAuthentication JWT

If you're using AshAuthentication's built-in JWT tokens (not OIDC):

```elixir
# Environment
MCP_PUBLIC_URL=https://api.example.com
MCP_REQUIRED_SCOPES=mcp:access

# Pipeline (default verifier)
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    resource_path: "/mcp",
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end

# Router (no authorization_servers)
forward "/", AshAi.Mcp.Router,
  otp_app: :my_app,
  resource_path: "/mcp",
  public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
  required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
  oauth_required?: true,
  tools: []
```

## Advanced Configuration

### Multiple Issuers (Multi-tenant)

For multi-tenant applications with different IdPs per tenant:

```elixir
verifier_context: [
  issuers: [
    "https://tenant1.auth0.com",
    "https://tenant2.auth0.com"
  ],
  resource_indicator: "https://api.example.com/mcp",
  actor_resource: MyApp.Accounts.User,
  algorithms: ["RS256"]
]

You may also use `issuer: "…"` for a single issuer. When multiple issuers are provided,
the verifier selects the issuer whose JWKS contains the presented token's `kid`.

### Clock Skew Tolerance

OAuth ecosystems can experience slight clock drift across systems. The verifier applies
a configurable clock skew tolerance (default 30 seconds) when checking `exp` (token expiry)
and `nbf` (not-before) claims to reduce false negatives. You can override this in your
`verifier_context`:

```elixir
verifier_context: [
  issuer: "https://my-idp.com",
  resource_indicator: "https://api.example.com/mcp",
  actor_resource: MyApp.Accounts.User,
  algorithms: ["RS256"],
  clock_skew_seconds: 60  # Optional: defaults to 30
]
```

Ensure your systems have reasonable clock synchronization; tokens that are significantly
past expiry are still rejected.
```

### Custom Signing Algorithms

```elixir
verifier_context: [
  issuer: "https://my-idp.com",
  resource_indicator: "https://api.example.com/mcp",
  actor_resource: MyApp.Accounts.User,
  algorithms: ["RS256", "RS384", "RS512"]
]
```

### Custom Subject Resolver

If your actor resolution differs from AshAuthentication's default:

```elixir
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &AshAi.Mcp.Auth.OidcJwksVerifier.verify/4,
    verifier_context: [...],
    subject_resolver: &MyApp.CustomResolver.resolve/3,
    public_base_url: System.fetch_env!("MCP_PUBLIC_URL"),
    required_scopes: System.fetch_env!("MCP_REQUIRED_SCOPES"),
    required?: true
end
```

The subject resolver must implement:

```elixir
@spec resolve(subject :: String.t(), resource :: module(), opts :: keyword()) ::
  {:ok, actor :: struct()} | {:error, status, error_code, reason, description, attrs}
```

### Custom Token Verifier

For non-OIDC providers or custom verification logic:

```elixir
defmodule MyApp.CustomVerifier do
  @spec verify(token :: String.t(), target :: atom(), opts :: keyword(), context :: map()) ::
    {:ok, claims :: map(), resource :: module()} | :error
  def verify(token, _target, _opts, context) do
    # Custom verification logic
    # Must return {:ok, claims, resource} or :error
  end
end

# In pipeline
pipeline :mcp do
  plug AshAi.Mcp.Auth.OAuthBearerPlug,
    otp_app: :my_app,
    verifier: &MyApp.CustomVerifier.verify/4,
    verifier_context: %{...},
    ...
end
```

## Telemetry

AshAi emits telemetry events for OAuth verification and tool execution, enabling observability,
alerting, and audit trails. All events include `:otp_app` in metadata for multi-app deployments.

### OAuth Events

**`[:ash_ai, :mcp, :oauth, :verify]`** - Token verification attempt

Measurements:
- `:duration` - Verification time in microseconds

Metadata:
- `:status` - `:ok` or `:error`
- `:reason` - Error reason atom (`:invalid_token`, etc.) when status is `:error`
- `:otp_app` - Application atom
- `:resource_indicator` - Expected resource indicator
- `:issuer` - Primary issuer (if configured)
- `:issuers` - List of all configured issuers
- `:verifier` - Verifier function name

**`[:ash_ai, :mcp, :oauth, :audience_mismatch]`** - Token audience doesn't match resource indicator

Measurements:
- `:count` - Always 1

Metadata:
- `:status` - Always `:error`
- `:otp_app` - Application atom
- `:resource_indicator` - Expected resource indicator
- `:provided_audiences` - List of audiences from token (max 5)

**`[:ash_ai, :mcp, :oauth, :insufficient_scope]`** - Token missing required scopes

Measurements:
- `:count` - Number of missing scopes

Metadata:
- `:status` - Always `:error`
- `:otp_app` - Application atom
- `:required_scopes` - List of required scopes
- `:missing_scopes` - List of missing scopes
- `:granted_scopes` - List of granted scopes from token

### Tool Events

**`[:ash_ai, :mcp, :tools, :list]`** - Tools list requested

Measurements:
- `:duration` - Request processing time in microseconds

Metadata:
- `:count` - Number of tools returned
- `:otp_app` - Application atom

**`[:ash_ai, :mcp, :tools, :call]`** - Tool execution

Measurements:
- `:duration` - Execution time in microseconds

Metadata:
- `:status` - `:ok` or `:error`
- `:tool` - Tool name
- `:otp_app` - Application atom
- `:resource` - Ash resource module
- `:action` - Ash action name (if available)
- `:tenant` - Tenant identifier (if multi-tenant)
- `:reason` - Error reason atom (`:tool_not_found`, `:tool_execution_error`) when status is `:error`

### Telemetry Handler Example

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def handle_event([:ash_ai, :mcp, :oauth, :verify], measurements, metadata, _config) do
    case metadata.status do
      :ok ->
        Logger.info("OAuth verification succeeded",
          duration_us: measurements.duration,
          issuer: metadata[:issuer]
        )

      :error ->
        Logger.warning("OAuth verification failed",
          duration_us: measurements.duration,
          reason: metadata[:reason],
          issuer: metadata[:issuer]
        )
    end
  end

  def handle_event([:ash_ai, :mcp, :oauth, :insufficient_scope], measurements, metadata, _config) do
    Logger.warning("Insufficient OAuth scopes",
      missing: metadata.missing_scopes,
      required: metadata.required_scopes,
      granted: metadata.granted_scopes
    )

    # Send alert if critical scope is missing
    if "admin:write" in metadata.missing_scopes do
      MyApp.Alerts.send_security_alert(:privilege_escalation_attempt, metadata)
    end
  end

  def handle_event([:ash_ai, :mcp, :tools, :call], measurements, metadata, _config) do
    case metadata.status do
      :ok ->
        Logger.info("Tool executed successfully",
          tool: metadata.tool,
          duration_ms: div(measurements.duration, 1000),
          resource: metadata.resource
        )

        # Track metrics
        :telemetry.execute(
          [:my_app, :mcp, :tool_success],
          %{count: 1},
          %{tool: metadata.tool}
        )

      :error ->
        Logger.error("Tool execution failed",
          tool: metadata.tool,
          reason: metadata.reason,
          duration_ms: div(measurements.duration, 1000)
        )
    end
  end
end

# In application.ex
:telemetry.attach_many(
  "mcp-oauth-handler",
  [
    [:ash_ai, :mcp, :oauth, :verify],
    [:ash_ai, :mcp, :oauth, :audience_mismatch],
    [:ash_ai, :mcp, :oauth, :insufficient_scope],
    [:ash_ai, :mcp, :tools, :list],
    [:ash_ai, :mcp, :tools, :call]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

## Testing

### Verify Protected Resource Metadata

```bash
curl https://your-app.com/.well-known/oauth-protected-resource \
  -H 'MCP-Protocol-Version: 2025-06-18'
```

Expected response:

```json
{
  "resource": "https://your-app.com/mcp",
  "authorization_servers": ["https://my-tenant.auth0.com/.well-known/oauth-authorization-server"],
  "scopes_supported": ["mcp:access"],
  "bearer_methods_supported": ["authorization_header"],
  "resource_signing_algorithms_supported": ["RS256"]
}
```

### Validate Authentication Failures

Missing token:

```bash
curl https://your-app.com/mcp \
  -H 'MCP-Protocol-Version: 2025-06-18'
```

Expected: `401` with `WWW-Authenticate: Bearer error="invalid_token" error_description="Bearer access token required"`

Invalid token:

```bash
curl https://your-app.com/mcp \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Authorization: Bearer invalid-token'
```

Expected: `401` with `WWW-Authenticate: Bearer error="invalid_token" error_description="Bearer token could not be verified"`

Wrong audience:

```bash
curl https://your-app.com/mcp \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Authorization: Bearer <valid-token-wrong-audience>'
```

Expected: `401` with `WWW-Authenticate: Bearer error="invalid_scope" error_description="Token audience does not match required resource indicator"`

Insufficient scopes:

```bash
curl https://your-app.com/mcp \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Authorization: Bearer <valid-token-missing-scopes>'
```

Expected: `403` with `WWW-Authenticate: Bearer error="insufficient_scope" scope="mcp:access" missing="mcp:access"`

### Successful Request

```bash
curl https://your-app.com/mcp \
  -H 'MCP-Protocol-Version: 2025-06-18' \
  -H 'Authorization: Bearer <valid-token>' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list"}'
```

Expected: `200` with structured JSON-RPC response

## WWW-Authenticate Error Matrix

AshAi normalises OAuth errors to RFC 6750 compliant headers. The telemetry metadata attached to
each event mirrors the entries below so you can correlate failures out-of-band.

| Condition | HTTP status | `error` | Notes |
|-----------|-------------|---------|-------|
| Missing/malformed header | 401 | `invalid_token` | `error_description` clarifies whether the header was missing or not using the Bearer scheme |
| Signature/expiry failure | 401 | `invalid_token` | Telemetry reports `reason: :invalid_token` |
| Audience mismatch | 401 | `invalid_scope` | `resource` parameter echoes the expected resource indicator |
| Missing scopes | 403 | `insufficient_scope` | `scope` and `missing` parameters enumerate requirements |

### Dynamic WWW-Authenticate Parameters

Use `www_authenticate_params` to append custom parameters to the `WWW-Authenticate` header,
such as support URLs or escalation contacts. Multiple formats are supported:

**Static keyword list:**

```elixir
plug AshAi.Mcp.Auth.OAuthBearerPlug,
  www_authenticate_params: [
    error_contact: "mailto:security@example.com",
    realm: "api"
  ]
```

**Static map:**

```elixir
plug AshAi.Mcp.Auth.OAuthBearerPlug,
  www_authenticate_params: %{
    error_contact: "mailto:security@example.com"
  }
```

**Dynamic function (receives error context):**

```elixir
plug AshAi.Mcp.Auth.OAuthBearerPlug,
  www_authenticate_params: fn context ->
    case context do
      %{error: "invalid_token", reason: :invalid_issuer} ->
        [error_contact: "mailto:security@example.com"]

      %{error: "insufficient_scope", status: 403} ->
        [error_uri: "https://docs.example.com/scopes"]

      _ ->
        []
    end
  end
```

The function receives a context map with:
- `:status` - HTTP status code (401, 403)
- `:error` - OAuth error code ("invalid_token", "insufficient_scope", etc.)
- `:reason` - Internal reason atom
- `:description` - Error description string
- `:attrs` - Additional error attributes

## Resource Links & Meta Builders

Tool responses expose two hooks:

- `resource_link_builder`: build `resourceLinks` for a tool invocation using Phoenix routes
- `meta_builder`: merge arbitrary keys into the `_meta` map

When `public_base_url` is omitted, AshAi still returns a fully compliant `tool_result`; the
`resourceLinks` array simply remains empty.

### Resource Link Builder

The `resource_link_builder` can be configured at two levels:

1. **Router level** (recommended with `--wrappers`): applies to all tools
2. **Tool level**: configured on individual tool definitions

Router-level builders take precedence. The builder receives three arguments:

- `tool`: The tool definition struct with metadata
- `data`: The decoded result data
- `context`: Map with `:tool`, `:router_opts`, `:public_base_url`, etc.

```elixir
# In MyAppWeb.McpRouter
def resource_links(tool, data, _context) do
  case tool.action.name do
    :list ->
      Enum.map(List.wrap(data), fn %{"id" => id} ->
        %{
          "href" => Routes.post_url(MyAppWeb.Endpoint, :show, id),
          "title" => "Post #{id}",
          "type" => "application/vnd.api+json",
          "_meta" => %{"rel" => "item"}
        }
      end)

    _ ->
      []
  end
end
```

### Meta Builder

The `meta_builder` augments the `_meta` object in tool responses. It receives a context map
with `:data`, `:session_id`, `:request_id`, and additional tool execution context.

**Supported return formats:**

```elixir
# Simple map - merged into _meta
def meta_builder(_context) do
  %{"correlationId" => UUID.uuid4()}
end

# Tuple with :ok - merged into _meta
def meta_builder(_context) do
  {:ok, %{"version" => "1.0"}}
end

# Tuple with :ok and resource_links - meta merged, links appended
def meta_builder(%{data: data}) do
  links = build_links_from_data(data)
  {:ok, %{"count" => length(data)}, links}
end

# Map with :meta key - meta merged, optional :resource_links appended
def meta_builder(_context) do
  %{
    meta: %{"environment" => "production"},
    resource_links: [%{"href" => "...", "title" => "..."}]
  }
end
```

Resource links from `meta_builder` are appended to links from `resource_link_builder` or
explicit tool `resource_links`.

## Legacy Compatibility

Some IDEs and proxies still speak older MCP versions. Generate scaffolding that advertises the legacy protocol by passing `--allow-legacy-protocol`:

```bash
mix ash_ai.gen.mcp --user MyApp.Accounts.User --allow-legacy-protocol
```

The router continues to enforce the 2025-06-18 header but emits a warning so you remember to remove the flag once clients update.

## Troubleshooting

### Token Verification Fails

- Ensure `MCP_ISSUER` matches the `iss` claim in your token exactly (trailing slashes matter)
- Verify `MCP_RESOURCE_INDICATOR` matches the `aud` claim in your token
- Check that the signing algorithm matches (default is RS256)

### JWKS Cache Architecture

The JWKS cache is implemented as a supervised GenServer (`AshAi.Mcp.Auth.JwksCache`) with
several security and performance features:

**Security**:
- **Protected ETS table**: Only the GenServer can write to the cache, preventing cache poisoning attacks
- **SSRF protection**: Validates issuer URLs to block private networks (192.168.x.x, 10.x.x.x, 172.16-31.x.x) and localhost
- **HTTPS enforcement**: Rejects insecure issuer URLs
- **Input validation**: Validates JWKS responses to prevent GenServer crashes from malformed data

**Performance**:
- **Async pre-warming**: JWKS are refreshed in the background when nearing expiration (60s before TTL)
- **Kid-to-issuer index**: O(1) issuer lookup in multi-tenant scenarios using the token's `kid` (key ID)
- **Read concurrency**: Multiple processes can read from the cache simultaneously
- **Request deduplication**: Concurrent requests for the same issuer are coalesced into a single fetch

**Fault Tolerance**:
- **Task crash recovery**: If a JWKS fetch task crashes, waiting clients receive an error response and the cache remains operational
- **Supervised GenServer**: The cache GenServer is supervised and will restart if it crashes, though active requests will fail
- **Automatic retry on key rotation**: If signature verification fails, the verifier automatically refreshes JWKS once

JWKS are cached based on `Cache-Control` headers (default 15 minutes). If keys rotate, the
verifier automatically triggers a refresh on signature failure.

To manually clear the cache during development:

```elixir
AshAi.Mcp.Auth.JwksCache.clear_cache()
```

To force a refresh for a specific issuer:

```elixir
AshAi.Mcp.Auth.JwksCache.force_refresh("https://my-tenant.auth0.com")
```

### Subject Resolution Fails

Ensure your `actor_resource` in `verifier_context` matches the resource configured in AshAuthentication. The subject (`sub` claim) must be resolvable to an actor in your system.

### Multiple Tenants

If using multi-tenancy, ensure your token includes a `tenant` claim. The plug automatically sets the tenant context when present.

 
