defmodule Cardbox.FileFieldTest do
  use CardboxTest.DataCase

  @invoice %{
    key: "2026/11/1f2e-edp-2026-11.pdf",
    url: "/uploads/kotoba/2026/11/1f2e-edp-2026-11.pdf",
    name: "edp-2026-11.pdf",
    content_type: "application/pdf",
    bytes: 48_211
  }

  defp bills! do
    {:ok, collection} =
      Box.create_collection(%{
        name: "Bills",
        owner: {"workspace", 1},
        fields: [
          %{name: "Payee", type: "text"},
          %{name: "Amount", type: "number", options: %{format: "currency", currency: "EUR"}},
          %{name: "Invoice", type: "file"}
        ]
      })

    collection
  end

  test "keeps where each file is and what it is, from maps of atom or string keys" do
    collection = bills!()
    record = insert!(collection, %{"Payee" => "EDP", "Invoice" => @invoice})

    assert record.data["invoice"] == [
             %{
               "key" => @invoice.key,
               "url" => @invoice.url,
               "name" => "edp-2026-11.pdf",
               "content_type" => "application/pdf",
               "bytes" => 48_211
             }
           ]

    receipt = %{key: "r", url: "https://cdn.example/r.jpg", name: "receipt.jpg"}

    {:ok, record} =
      Box.update(collection, record.id, %{
        "Invoice" => [Map.new(@invoice, fn {k, v} -> {to_string(k), v} end), receipt]
      })

    assert [
             %{"name" => "edp-2026-11.pdf"},
             %{"name" => "receipt.jpg", "content_type" => "application/octet-stream"}
           ] =
             record.data["invoice"]

    assert Cardbox.Record.to_map(record, collection)["Invoice"] == record.data["invoice"]
  end

  test "refuses a file that a page could not show safely, saying what is wrong" do
    collection = bills!()

    for {file, message} <- [
          {%{@invoice | url: "javascript:alert(1)"},
           "is a file whose url is a path (/...) or starts with https://"},
          {%{@invoice | url: "//evil.example/x.pdf"}, "is a file whose url is a path"},
          {%{@invoice | content_type: "text/html; charset=utf-8"},
           "is a file whose content_type is a media type"},
          {%{@invoice | bytes: -1}, "is a file whose bytes are a whole number"},
          {Map.delete(@invoice, :key), "is a file with its key"},
          {"edp.pdf", "is a file: a map with its key, url and name"}
        ] do
      assert {:error, %Error{errors: [{"invoice", got}]}} =
               Box.insert(collection, %{"Invoice" => file})

      assert got =~ message
    end

    many = for n <- 1..21, do: %{@invoice | key: "k#{n}"}

    assert {:error, %Error{errors: [{"invoice", "holds at most 20 files"}]}} =
             Box.insert(collection, %{"Invoice" => many})
  end

  test "a name loses its control characters, and the same file twice is once" do
    record =
      insert!(bills!(), %{
        "Invoice" => [%{@invoice | name: "edp\u0000\u202E.pdf"}, @invoice]
      })

    assert [%{"name" => "edp.pdf"}] = record.data["invoice"]
  end

  test "filters by being empty or not, and searches by the files' names" do
    collection = bills!()
    insert!(collection, %{"Payee" => "EDP", "Invoice" => @invoice})
    insert!(collection, %{"Payee" => "Water"})

    assert {:ok, [%{data: %{"payee" => "Water"}}]} =
             Box.list(collection, %{"filter" => %{"field" => "Invoice", "op" => "is_empty"}})

    assert {:ok, [%{data: %{"payee" => "EDP"}}]} =
             Box.list(collection, %{"filter" => %{"field" => "Invoice", "op" => "is_not_empty"}})

    assert {:ok, [%{data: %{"payee" => "EDP"}}]} = Box.list(collection, %{"search" => "edp-2026"})

    assert {:error, %Error{}} =
             Box.list(collection, %{
               "filter" => %{"field" => "Invoice", "op" => "has_any", "value" => ["x"]}
             })
  end

  test "a field that becomes a text keeps the files' names" do
    collection = bills!()
    record = insert!(collection, %{"Invoice" => @invoice})
    {:ok, collection} = Box.update_field(collection, "Invoice", %{type: "text"})

    assert Box.get(collection, record.id).data["invoice"] == "edp-2026-11.pdf"
  end

  test "a JSON schema for agents" do
    %{"properties" => %{"invoice" => %{"anyOf" => [files, _null]}}} =
      Cardbox.JSONSchema.schema(bills!())

    assert %{"type" => "array", "items" => %{"required" => ["key", "url", "name"]}} = files
  end

  test "a table shows the files by name, and does not edit them" do
    collection = bills!()

    record =
      insert!(collection, %{"Invoice" => [@invoice, %{@invoice | key: "2", name: "page 2.pdf"}]})

    invoice = Enum.find(Cardbox.Masu.columns(collection, nil), &(&1[:key] == "invoice"))
    assert invoice[:editable] == false
    assert invoice[:type] == :text

    assert Cardbox.Masu.row(collection, record)["invoice"] == "edp-2026-11.pdf, page 2.pdf"
  end
end
