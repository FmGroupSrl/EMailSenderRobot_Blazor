namespace EMailSender.Core.Models;

/// <summary>
/// Rappresenta una riga della tabella ConfigEmailJobSchedule
/// </summary>
public class EmailJob
{
    public int EmailId { get; set; }
    public string Company { get; set; } = "";
    public string JobReference { get; set; } = "";
    public string EmailType { get; set; } = "";
    public bool EmailBodyIsHtml { get; set; }
    public string EmailObject { get; set; } = "";
    public string EmailBody { get; set; } = "";
    public string EmailTo { get; set; } = "";
    public string EmailCC { get; set; } = "";
    public string EmailCCN { get; set; } = "";
    public string EmailAttachments { get; set; } = "";
    public DateTime? CreationTimeStamp { get; set; }
    public DateTime? SentTimeStamp { get; set; }
    public string IsError { get; set; } = "N"; // N=nessuno, S=errore, A=annullata
    public string ErrorMessage { get; set; } = "";
    public int RetryCount { get; set; }
    public string IsScheduled { get; set; } = "N";
}

/// <summary>
/// Parametri del server SMTP letti dalla tabella ConfigEmailServer
/// </summary>
public class EmailServerConfig
{
    public string Company { get; set; } = "";
    public string Smtp_Server { get; set; } = "";
    public int Smtp_Port { get; set; }
    public bool Smtp_Ssl { get; set; }
    public bool Smtp_StartTls { get; set; }
    public bool Smtp_Auth { get; set; }
    public string Smtp_User { get; set; } = "";
    public string Smtp_Password { get; set; } = "";
    public string Smtp_Sender { get; set; } = "";
    public string Smtp_SenderAlias { get; set; } = "";
}

/// <summary>
/// Parametri DKIM letti dall'appsettings.json — NON dal DB
/// </summary>
public class DkimConfig
{
    public string PrivateKeyBase64 { get; set; } = "";
    public string Domain { get; set; } = "";
    public string Selector { get; set; } = "";
}

/// <summary>
/// Configurazione completa di una company — letta dall'appsettings.json.
/// I parametri SMTP stanno invece sul DB (ConfigEmailServer).
/// </summary>
public class CompanySettings
{
    public string Name { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public int BatchSize { get; set; } = 10;
    public int MaxRetryCount { get; set; } = 2;
    public int LogRetentionDays { get; set; } = 30;
    public string LogDirectory { get; set; } = "";
    public string BackupCompany { get; set; } = "";
    public string BackupEmailType { get; set; } = "";
    public string SqlConfigTableServer { get; set; } = "ConfigEmailServer";
    public string SemaphoreFilePath { get; set; } = "";
    public DkimConfig Dkim { get; set; } = new();

    // Proprietà calcolate — non serializzate nel JSON
    public bool IsSemaphoreRed => !string.IsNullOrWhiteSpace(SemaphoreFilePath)
                                  && File.Exists(SemaphoreFilePath);
}

/// <summary>
/// Voce del log applicativo (tabella log)
/// </summary>
public class LogEntry
{
    public int Id { get; set; }
    public string Company { get; set; } = "";
    public string Data { get; set; } = "";
    public string Ora { get; set; } = "";
    public string Tipo { get; set; } = "";
    public string Operazione { get; set; } = "";
    public string Descr { get; set; } = "";
}