namespace EMailSender.Core.Services;

/// <summary>
/// Scrive un file di log su disco per ogni esecuzione dell'EXE.
/// Un file per giorno, nella directory configurata per la company.
/// Nome file: EMailSender_yyyyMMdd.log
/// </summary>
public class FileLogger
{
    private readonly string _logDir;
    private readonly string _logFile;

    public FileLogger(string logDirectory)
    {
        _logDir = logDirectory;
        _logFile = Path.Combine(logDirectory, $"EMailSender_{DateTime.Now:yyyyMMdd}.log");
    }

    public void Write(string level, string operation, string message)
    {
        try
        {
            if (!Directory.Exists(_logDir))
                Directory.CreateDirectory(_logDir);

            var line = $"{DateTime.Now:HH:mm:ss} [{level,-8}] {operation,-25} {message}";
            File.AppendAllText(_logFile, line + Environment.NewLine);
            Console.WriteLine(line);  // scrive anche a console (visibile in Task Scheduler log)
        }
        catch
        {
            // Se il log su file fallisce non blocchiamo la spedizione
        }
    }

    public void Info(string operation, string message) => Write("INFO", operation, message);
    public void Ok(string operation, string message) => Write("OK", operation, message);
    public void Error(string operation, string message) => Write("ERRORE", operation, message);
    public void Warn(string operation, string message) => Write("WARNING", operation, message);

    /// <summary>
    /// Elimina i file di log più vecchi di <paramref name="retentionDays"/> giorni.
    /// Restituisce il numero di file cancellati, così il chiamante può darne conto.
    /// </summary>
    public int Cleanup(int retentionDays)
    {
        int deleted = 0;

        try
        {
            if (!Directory.Exists(_logDir)) return 0;

            var cutoff = DateTime.Now.AddDays(-retentionDays);
            foreach (var file in Directory.GetFiles(_logDir, "EMailSender_*.log"))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                {
                    File.Delete(file);
                    deleted++;
                }
            }
        }
        catch
        {
            // La pulizia non deve mai impedire la spedizione: un errore qui
            // (file in uso, permessi) viene ignorato e riprovato domani.
        }

        return deleted;
    }

    /// <summary>
    /// Data dell'ultima manutenzione eseguita, letta da un file marcatore nella
    /// cartella di log. Restituisce DateTime.MinValue se non è mai stata fatta.
    ///
    /// Serve a far girare la pulizia UNA VOLTA AL GIORNO: il job parte ogni
    /// minuto, e ripetere ad ogni esecuzione una DELETE sulla tabella log
    /// significherebbe 1440 query al giorno per tenant, per lo più inutili.
    /// </summary>
    public DateTime GetLastMaintenance()
    {
        try
        {
            var marker = Path.Combine(_logDir, "lastcleanup.txt");
            if (!File.Exists(marker)) return DateTime.MinValue;

            var text = File.ReadAllText(marker).Trim();
            if (DateTime.TryParse(text, out var when)) return when;
        }
        catch { }

        return DateTime.MinValue;
    }

    /// <summary>
    /// Registra che la manutenzione è stata eseguita adesso.
    /// </summary>
    public void SetLastMaintenance()
    {
        try
        {
            if (!Directory.Exists(_logDir))
                Directory.CreateDirectory(_logDir);

            File.WriteAllText(Path.Combine(_logDir, "lastcleanup.txt"),
                              DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        }
        catch { }
    }
}