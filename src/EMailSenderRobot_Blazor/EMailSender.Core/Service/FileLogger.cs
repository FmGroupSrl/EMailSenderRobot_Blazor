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
    /// </summary>
    public void Cleanup(int retentionDays)
    {
        try
        {
            if (!Directory.Exists(_logDir)) return;

            var cutoff = DateTime.Now.AddDays(-retentionDays);
            foreach (var file in Directory.GetFiles(_logDir, "EMailSender_*.log"))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                    File.Delete(file);
            }
        }
        catch { }
    }
}