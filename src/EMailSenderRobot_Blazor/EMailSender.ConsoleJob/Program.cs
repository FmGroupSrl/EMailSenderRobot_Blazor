using EMailSender.Core.Data;
using EMailSender.Core.Models;
using EMailSender.Core.Services;
using Microsoft.Extensions.Configuration;

// ---------------------------------------------------------------------------
// Parsing argomenti da riga di comando
// Uso: EMailSender.ConsoleJob.exe --batch 10 --company "CompanyA"
// ---------------------------------------------------------------------------
string? argCompany = null;
int? argBatch = null;

for (int i = 0; i < args.Length - 1; i++)
{
    if (args[i] == "--company") argCompany = args[i + 1];
    if (args[i] == "--batch" && int.TryParse(args[i + 1], out int b)) argBatch = b;
}

// ---------------------------------------------------------------------------
// Caricamento configurazione da appsettings.json
// ---------------------------------------------------------------------------
var config = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var jobCfg = config.GetSection("EmailJob");
int maxRetry = jobCfg.GetValue<int>("MaxRetryCount", 2);

string company = argCompany ?? jobCfg.GetValue<string>("DefaultCompany", "")!;

if (string.IsNullOrWhiteSpace(company))
{
    Console.WriteLine("[ERRORE] Company non specificata. Usa --company \"NomeCompany\"");
    return;
}

// ---------------------------------------------------------------------------
// ConfigService + FileLogger
// ---------------------------------------------------------------------------
var cfgService = new ConfigService(Path.Combine(AppContext.BaseDirectory, "appsettings.json"));
var companyCfg = cfgService.GetCompany(company);
var fileLog = new FileLogger(companyCfg?.LogDirectory
                                ?? Path.Combine(AppContext.BaseDirectory, "Logs"));

// Batch size: da riga di comando oppure da appsettings della company
int batchSize = argBatch ?? companyCfg?.BatchSize ?? 10;

// Tabella config SMTP: dalla company, con fallback al default
string sqlTable = companyCfg?.SqlConfigTableServer ?? "ConfigEmailServer";

// ---------------------------------------------------------------------------
// Controllo semaforo rosso
// ---------------------------------------------------------------------------
if (cfgService.IsBlocked())
{
    fileLog.Warn("EMailSenderJob", "Spedizioni BLOCCATE (IsBlocked=true). Uscita.");
    return;
}

// ---------------------------------------------------------------------------
// Connection strings
// ---------------------------------------------------------------------------
string? connStrMain = config.GetConnectionString($"{company}_Main");
string? connStrLog = config.GetConnectionString($"{company}_Log");

if (string.IsNullOrWhiteSpace(connStrMain))
{
    fileLog.Error("EMailSenderJob", $"ConnectionString '{company}_Main' non trovata.");
    return;
}
if (string.IsNullOrWhiteSpace(connStrLog))
{
    fileLog.Error("EMailSenderJob", $"ConnectionString '{company}_Log' non trovata.");
    return;
}

// ---------------------------------------------------------------------------
// DKIM
// ---------------------------------------------------------------------------
var dkimCfg = companyCfg?.Dkim;

// ---------------------------------------------------------------------------
// Esecuzione job
// ---------------------------------------------------------------------------
var repo = new EmailRepository(connStrMain);
var log = new EmailRepository(connStrLog);

fileLog.Info("EMailSenderJob", $"Avviato — company: {company} | batch: {batchSize} | tabella: {sqlTable}");

if (dkimCfg is not null && !string.IsNullOrWhiteSpace(dkimCfg.PrivateKeyBase64))
    fileLog.Info("EMailSenderJob", $"DKIM attivo — dominio: {dkimCfg.Domain} | selector: {dkimCfg.Selector}");

try
{
    repo.MarkJobsAsScheduled(batchSize);
    var jobs = repo.GetScheduledJobs();

    fileLog.Info("EMailSenderJob", $"Job trovati: {jobs.Count}");

    foreach (var job in jobs)
        ProcessJob(job);

    fileLog.Cleanup(companyCfg?.LogRetentionDays ?? 30);
}
catch (Exception ex)
{
    fileLog.Error("EMailSenderJob", $"Errore generale: {ex.Message}");
    log.WriteLog(company, "EMailSenderJob", $"Errore generale: {ex.Message}", "ERRORE");
}

fileLog.Info("EMailSenderJob", "Completato.");

// ---------------------------------------------------------------------------
// Elaborazione singolo job
// ---------------------------------------------------------------------------
void ProcessJob(EmailJob job)
{
    fileLog.Info("ProcessJob", $"EmailId {job.EmailId} | To: {job.EmailTo}");

    var serverCfg = repo.GetServerConfig(job.Company, sqlTable);
    if (serverCfg is null)
    {
        var errMsg = $"Config SMTP non trovata per company '{job.Company}' su tabella '{sqlTable}'";
        fileLog.Error("ProcessJob", errMsg);
        repo.MarkJobFailed(job.EmailId, job.RetryCount + 1, errMsg);
        log.WriteLog(job.Company, "EMailSenderJob", errMsg, "ERRORE");
        return;
    }

    var svc = new MailSenderService();
    svc.SetServerConfig(serverCfg);
    svc.SetDkimConfig(dkimCfg);

    if (!string.IsNullOrEmpty(job.EmailTo)) svc.TO = job.EmailTo.Split(';');
    if (!string.IsNullOrEmpty(job.EmailCC)) svc.CC = job.EmailCC.Split(';');
    if (!string.IsNullOrEmpty(job.EmailCCN)) svc.BCC = job.EmailCCN.Split(';');
    if (!string.IsNullOrEmpty(job.EmailAttachments)) svc.Attachments = job.EmailAttachments.Split(';');

    svc.EmailObject = job.EmailObject;
    svc.EmailFullBody = job.EmailBody;

    bool hasError = svc.SendEmail(isHtml: job.EmailBodyIsHtml, attempts: 2);

    if (!hasError)
    {
        repo.MarkJobSent(job.EmailId);
        log.WriteLog(job.Company, "EMailSenderJob", $"Email ID {job.EmailId} spedita con successo.", "RISULTATO");
        fileLog.Ok("ProcessJob", $"EmailId {job.EmailId} spedita.");
    }
    else
    {
        fileLog.Error("ProcessJob", $"EmailId {job.EmailId} errore: {svc.ErrorMessage}");
        log.WriteLog(job.Company, "EMailSenderJob", $"Email ID {job.EmailId} errore: {svc.ErrorMessage}", "ERRORE");

        if (job.RetryCount >= maxRetry)
        {
            repo.MarkJobCancelled(job.EmailId);
            fileLog.Warn("ProcessJob", $"EmailId {job.EmailId} annullata — raggiunto limite tentativi ({maxRetry}).");
        }
        else
        {
            repo.MarkJobFailed(job.EmailId, job.RetryCount + 1, svc.ErrorMessage);
        }
    }
}