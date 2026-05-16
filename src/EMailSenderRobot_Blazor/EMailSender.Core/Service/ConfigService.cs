using System.Text.Json;
using System.Text.Json.Nodes;
using EMailSender.Core.Models;

namespace EMailSender.Core.Services;

/// <summary>
/// Legge e scrive la configurazione delle company sull'appsettings.json condiviso.
/// La Web UI usa questo servizio per aggiungere/modificare/rimuovere company
/// e i relativi parametri (DKIM, BatchSize, LogDir, ecc.).
///
/// Le ConnectionStrings vengono gestite separatamente perché hanno
/// una struttura piatta nel JSON ({CompanyName}_Main / {CompanyName}_Log).
/// </summary>
public class ConfigService
{
    private readonly string _appSettingsPath;

    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = null   // mantiene i nomi esatti delle proprietà
    };

    public ConfigService(string appSettingsPath)
    {
        _appSettingsPath = appSettingsPath;
    }

    // -------------------------------------------------------------------------
    // LETTURA
    // -------------------------------------------------------------------------

    public List<CompanySettings> GetAllCompanies()
    {
        var root = ReadRoot();
        var arr = root["Companies"]?.AsArray();
        if (arr is null) return [];

        return arr
            .Select(n => n.Deserialize<CompanySettings>(_jsonOpts)!)
            .Where(c => c is not null)
            .ToList();
    }

    public CompanySettings? GetCompany(string name)
        => GetAllCompanies().FirstOrDefault(c => c.Name == name);

    public string? GetConnectionString(string key)
    {
        var root = ReadRoot();
        return root["ConnectionStrings"]?[key]?.GetValue<string>();
    }

    // -------------------------------------------------------------------------
    // SCRITTURA COMPANY
    // -------------------------------------------------------------------------

    /// <summary>
    /// Aggiunge una nuova company oppure aggiorna quella esistente con lo stesso Name.
    /// </summary>
    public void SaveCompany(CompanySettings company,
                            string connStrMain,
                            string connStrLog)
    {
        var root = ReadRoot();
        var companies = root["Companies"]?.AsArray() ?? new JsonArray();

        // Rimuove la company esistente con lo stesso nome (se c'è)
        var existing = companies
            .Select((n, i) => (node: n, idx: i))
            .FirstOrDefault(x => x.node?["Name"]?.GetValue<string>() == company.Name);

        if (existing.node is not null)
            companies.RemoveAt(existing.idx);

        // Serializza e reinserisce
        var node = JsonNode.Parse(JsonSerializer.Serialize(company, _jsonOpts))!;
        companies.Add(node);
        root["Companies"] = companies;

        // Aggiorna le ConnectionStrings
        var connStrings = root["ConnectionStrings"]?.AsObject() ?? new JsonObject();
        connStrings[$"{company.Name}_Main"] = connStrMain;
        connStrings[$"{company.Name}_Log"] = connStrLog;
        root["ConnectionStrings"] = connStrings;

        WriteRoot(root);
    }

    /// <summary>
    /// Rimuove una company e le sue ConnectionStrings dal file.
    /// </summary>
    public void RemoveCompany(string name)
    {
        var root = ReadRoot();
        var companies = root["Companies"]?.AsArray();
        if (companies is null) return;

        var toRemove = companies
            .Select((n, i) => (node: n, idx: i))
            .FirstOrDefault(x => x.node?["Name"]?.GetValue<string>() == name);

        if (toRemove.node is not null)
            companies.RemoveAt(toRemove.idx);

        // Rimuove anche le ConnectionStrings
        var cs = root["ConnectionStrings"]?.AsObject();
        cs?.Remove($"{name}_Main");
        cs?.Remove($"{name}_Log");

        WriteRoot(root);
    }

    // -------------------------------------------------------------------------
    // SEMAFORO ROSSO (globale — scritto in appsettings.json)
    // -------------------------------------------------------------------------

    public bool IsBlocked()
    {
        var root = ReadRoot();
        return root["IsBlocked"]?.GetValue<bool>() ?? false;
    }

    public void SetBlocked(bool blocked)
    {
        var root = ReadRoot();
        root["IsBlocked"] = blocked;
        WriteRoot(root);
    }

    // -------------------------------------------------------------------------
    // TENANT DEFAULT (sincronizzazione tipi mail)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Restituisce i nomi dei tenant "speciali" configurati in appsettings.json
    /// sotto la chiave DefaultTenants (es. ["Development", "FMGroup"]).
    /// Usati per sincronizzare automaticamente i tipi di mail creati/eliminati.
    /// </summary>
    public List<string> GetDefaultTenants()
    {
        var root = ReadRoot();
        var arr = root["DefaultTenants"]?.AsArray();
        if (arr is null) return [];

        return arr
            .Select(n => n?.GetValue<string>() ?? "")
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .ToList();
    }

    // -------------------------------------------------------------------------
    // HELPER PRIVATI
    // -------------------------------------------------------------------------

    private JsonObject ReadRoot()
    {
        if (!File.Exists(_appSettingsPath))
            return new JsonObject();

        var json = File.ReadAllText(_appSettingsPath);
        return JsonNode.Parse(json)?.AsObject() ?? new JsonObject();
    }

    private void WriteRoot(JsonObject root)
    {
        var json = root.ToJsonString(_jsonOpts);
        File.WriteAllText(_appSettingsPath, json);
    }
}