namespace EMailSender.Core.Services;

/// <summary>
/// Mantiene il tenant selezionato per tutta la sessione Blazor Server.
/// Registrato come Scoped in Program.cs — ogni connessione ha il suo stato.
/// Tutte le pagine lo iniettano per leggere/scrivere il tenant corrente
/// senza doverlo riselezionare ad ogni navigazione.
/// </summary>
public class TenantService
{
    private string _selectedCompany = "";

    public string SelectedCompany
    {
        get => _selectedCompany;
        set
        {
            if (_selectedCompany == value) return;
            _selectedCompany = value;
            OnTenantChanged?.Invoke();
        }
    }

    /// <summary>
    /// Evento scatenato quando il tenant cambia.
    /// Le pagine possono sottoscriversi per ricaricare i dati automaticamente.
    /// </summary>
    public event Action? OnTenantChanged;
}