# MCP OAuth Configuration

Ash AI ships an IdP-agnostic MCP router that supports OAuth 2.1 bearer tokens from any compliant identity provider. The router emits structured tool responses and resource metadata required by the 2025-06-18 MCP specification. This guide walks through the configuration and explains the moving parts.

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
```

## Configuration

### Environment Variables

All setups require:

```bash
MCP_PUBLIC_URL=https://your-app.com
MCP_REQUIRED_SCOPES=mcp:access
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
- `tools/list` and `tools/call` responses include structured content, `_meta` timing, and optional resource links

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
approximately 60 seconds of tolerance when checking `exp` (token expiry) and `nbf`
(not-before) claims to reduce false negatives. Ensure your systems have reasonable clock
synchronization; tokens that are significantly past expiry are still rejected.
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

### JWKS Cache Issues

JWKS are cached for 15 minutes by default. If keys rotate, the verifier automatically refreshes once on signature failure. To manually clear the cache during development:

```elixir
:ets.delete_all_objects(:ash_ai_jwks_cache)
```

### Subject Resolution Fails

Ensure your `actor_resource` in `verifier_context` matches the resource configured in AshAuthentication. The subject (`sub` claim) must be resolvable to an actor in your system.

### Multiple Tenants

If using multi-tenancy, ensure your token includes a `tenant` claim. The plug automatically sets the tenant context when present.

 
