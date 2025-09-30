defmodule AshAi.JsonSchema do
  @moduledoc false

  alias Ash.Resource.Info

  @doc """
  Builds a default JSON Schema for a tool's output based on the associated action
  and resource metadata. The schema is intentionally permissive to cover the
  different result shapes an Ash action may return while still providing useful
  structural hints to MCP clients.
  """
  def default_output_schema(tool) do
    case tool.action.type do
      :read -> read_schema(tool)
      :create -> single_resource_schema(tool)
      :update -> single_resource_schema(tool)
      :destroy -> single_resource_schema(tool)
      :action -> action_schema(tool)
      other when other in [:destroy, :bulk_destroy, :bulk_update] -> single_resource_schema(tool)
      _ -> %{"type" => "object"}
    end
  end

  defp read_schema(tool) do
    resource_schema = resource_schema(tool.resource, load: tool.load)

    %{
      "anyOf" => [
        %{
          "type" => "array",
          "items" => resource_schema,
          "description" => "Collection of #{inspect(tool.resource)} records"
        },
        %{"type" => "integer", "description" => "Count of matching records"},
        %{"type" => "boolean", "description" => "Whether any records exist"},
        %{
          "type" => "object",
          "description" => "Aggregate value",
          "additionalProperties" => true
        }
      ]
    }
  end

  defp single_resource_schema(tool) do
    resource_schema(tool.resource, load: tool.load)
  end

  defp action_schema(tool) do
    case tool.action.returns do
      nil -> %{"type" => "string", "description" => "Success message"}
      type -> type_schema(type, [])
    end
  end

  @doc """
  Generates a JSON Schema fragment representing an Ash resource. Only public
  attributes are described by default, with relationship data included when the
  tool explicitly loads them.
  """
  def resource_schema(resource, opts \\ []) do
    load = Keyword.get(opts, :load, [])

    properties =
      resource
      |> Info.public_attributes()
      |> Enum.reduce(%{}, fn attribute, acc ->
        Map.put(
          acc,
          to_string(attribute.name),
          type_schema(attribute.type, attribute.constraints)
        )
      end)
      |> maybe_add_relationships(resource, load)

    %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  defp maybe_add_relationships(properties, resource, load) do
    Enum.reduce(load, properties, fn
      {rel_name, nested_opts}, acc ->
        case Info.relationship(resource, rel_name) do
          %{cardinality: :many, destination: destination} ->
            schema = resource_schema(destination, load: nested_opts || [])

            Map.put(acc, to_string(rel_name), %{"type" => "array", "items" => schema})

          %{destination: destination} ->
            schema = resource_schema(destination, load: nested_opts || [])

            Map.put(acc, to_string(rel_name), schema)

          _ ->
            acc
        end

      rel_name, acc when is_atom(rel_name) ->
        case Info.relationship(resource, rel_name) do
          %{cardinality: :many, destination: destination} ->
            schema = resource_schema(destination, load: [])
            Map.put(acc, to_string(rel_name), %{"type" => "array", "items" => schema})

          %{destination: destination} ->
            schema = resource_schema(destination, load: [])
            Map.put(acc, to_string(rel_name), schema)

          _ ->
            acc
        end
    end)
  end

  @doc """
  Converts an Ash type into a JSON Schema fragment.
  """
  def type_schema({:array, type}, constraints) do
    item_constraints = Keyword.get(constraints, :items, [])

    %{
      "type" => "array",
      "items" => type_schema(type, item_constraints)
    }
  end

  def type_schema(type, constraints) do
    type = unwrap_new_type(type, constraints)

    cond do
      ash_resource?(type) -> resource_schema(type)
      match?(Ash.Type.Integer, type) -> %{"type" => "integer"}
      match?(Ash.Type.Float, type) -> %{"type" => "number"}
      match?(Ash.Type.Decimal, type) -> %{"type" => "string", "format" => "decimal"}
      match?(Ash.Type.Boolean, type) -> %{"type" => "boolean"}
      match?(Ash.Type.Date, type) -> %{"type" => "string", "format" => "date"}
      match?(Ash.Type.NaiveDatetime, type) -> %{"type" => "string", "format" => "date-time"}
      match?(Ash.Type.UtcDatetime, type) -> %{"type" => "string", "format" => "date-time"}
      match?(Ash.Type.Time, type) -> %{"type" => "string", "format" => "time"}
      match?(Ash.Type.UUID, type) -> %{"type" => "string", "format" => "uuid"}
      match?(Ash.Type.String, type) -> %{"type" => "string"}
      match?(Ash.Type.Map, type) -> %{"type" => "object", "additionalProperties" => true}
      match?(Ash.Type.Struct, type) -> %{"type" => "object"}
      function_type?(type) -> %{"type" => "string"}
      true -> %{"type" => "string"}
    end
  end

  defp unwrap_new_type(type, constraints) do
    if Ash.Type.NewType.new_type?(type) do
      subtype = Ash.Type.NewType.subtype_of(type)
      new_constraints = Ash.Type.NewType.constraints(type, constraints)
      unwrap_new_type(subtype, new_constraints)
    else
      type
    end
  end

  defp ash_resource?(module) when is_atom(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :__info__, 1) &&
      Info.resource?(module)
  end

  defp ash_resource?(_), do: false

  defp function_type?(type) do
    if function_exported?(type, :storage_type, 0) do
      match?({:ok, :string}, type.storage_type())
    else
      false
    end
  end
end
