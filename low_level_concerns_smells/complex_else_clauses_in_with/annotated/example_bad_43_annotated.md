# Annotated Example 43 — Complex else clauses in with

## Metadata

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `sign_document/3`, inside the `with` expression's `else` block
- **Affected function(s):** `sign_document/3`
- **Short explanation:** Five steps in the digital signing pipeline produce structurally different errors. Consolidating all of them into one flat `else` block hides which step originated a given failure, harming readability and long-term maintainability.

---

```elixir
defmodule Documents.SigningService do
  @moduledoc """
  Orchestrates digital document signing: document retrieval, signer authorization,
  cryptographic signing, audit trail recording, and finalization.
  """

  alias Documents.{
    DocumentRepo,
    SignerPolicy,
    CryptoEngine,
    AuditTrail,
    DocumentFinalizer
  }

  require Logger

  @doc """
  Signs `document_id` on behalf of `signer_id` using the given `signing_key`.

  Returns `{:ok, signed_document}` or a descriptive error.
  """
  @spec sign_document(String.t(), String.t(), binary()) ::
          {:ok, map()}
          | {:error, :document_not_found}
          | {:error, :signer_unauthorized}
          | {:error, :crypto_failed, String.t()}
          | {:error, :audit_failed}
          | {:error, :finalization_failed}
  def sign_document(document_id, signer_id, signing_key) do
    # VALIDATION: SMELL START - Complex else clauses in with
    # VALIDATION: This is a smell because five with-clauses each produce a
    # distinct error shape ({:error, :not_found}, {:error, :unauthorized, _},
    # {:error, :crypto, _}, {:error, :audit}, {:error, :finalize, _}).
    # The single else block must handle all of them flat, making it
    # impossible to tell which step is responsible for any given pattern.
    with {:ok, document}   <- DocumentRepo.fetch(document_id),
         :ok               <- SignerPolicy.assert_authorized(signer_id, document),
         {:ok, signature}  <- CryptoEngine.sign(document.content_hash, signing_key),
         :ok               <- AuditTrail.record_signature(%{
                                document_id: document_id,
                                signer_id:   signer_id,
                                algorithm:   signature.algorithm,
                                signed_at:   DateTime.utc_now()
                              }),
         {:ok, signed_doc} <- DocumentFinalizer.finalize(document, signature) do
      Logger.info("Document #{document_id} signed by #{signer_id}")
      {:ok, signed_doc}
    else
      {:error, :not_found} ->
        Logger.warn("Document #{document_id} not found")
        {:error, :document_not_found}

      {:error, :unauthorized, reason} ->
        Logger.warn("Signer #{signer_id} unauthorized for #{document_id}: #{reason}")
        {:error, :signer_unauthorized}

      {:error, :crypto, detail} ->
        Logger.error("Cryptographic signing failed: #{inspect(detail)}")
        {:error, :crypto_failed, inspect(detail)}

      {:error, :audit} ->
        Logger.error("Audit trail write failed for document #{document_id}")
        {:error, :audit_failed}

      {:error, :finalize, detail} ->
        Logger.error("Document finalization failed: #{inspect(detail)}")
        {:error, :finalization_failed}
    end
    # VALIDATION: SMELL END
  end
end
```
