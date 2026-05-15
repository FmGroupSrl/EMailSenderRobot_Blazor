using System.Data;
using Microsoft.Data.SqlClient;
using EMailSender.Core.Models;

namespace EMailSender.Core.Data;

/// <summary>
/// Accesso dati per le tabelle di gestione mail.
/// ADO.NET puro, coerente col codice ASPX esistente.
/// </summary>
public class EmailRepository
{
    private readonly string _connStr;

    public EmailRepository(string connectionString)
    {
        _connStr = connectionString;
    }

    // -------------------------------------------------------------------------
    // JOB QUEUE
    // -------------------------------------------------------------------------

    /// <summary>
    /// Marca come IsScheduled='S' le prime <paramref name="batchSize"/> mail
    /// non ancora spedite, con priorità a quelle già in errore.
    /// </summary>
    public void MarkJobsAsScheduled(int batchSize)
    {
        const string sql = @"
            UPDATE ConfigEmailJobSchedule
               SET IsScheduled = 'S'
             WHERE EmailId IN (
                   SELECT TOP (@batch) EmailId
                     FROM ConfigEmailJobSchedule
                    WHERE SentTimeStamp IS NULL
                      AND IsScheduled   = 'N'
                      AND (IsError = 'N' OR IsError = 'S')
                    ORDER BY IsError DESC, EmailId
             )";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@batch", SqlDbType.Int).Value = batchSize;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Legge tutti i job marcati come IsScheduled='S'.
    /// </summary>
    public List<EmailJob> GetScheduledJobs()
    {
        const string sql = "SELECT * FROM ConfigEmailJobSchedule WHERE IsScheduled = 'S'";
        var jobs = new List<EmailJob>();

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        conn.Open();
        using var rdr = cmd.ExecuteReader();
        while (rdr.Read())
            jobs.Add(MapJob(rdr));

        return jobs;
    }

    /// <summary>
    /// Legge tutti i job per il monitor (Web UI), ordinati per EmailId DESC.
    /// Se <paramref name="company"/> è valorizzato filtra per company.
    /// </summary>
    public List<EmailJob> GetAllJobs(int top = 500, string? company = null)
    {
        var sql = string.IsNullOrWhiteSpace(company)
            ? "SELECT TOP (@top) * FROM ConfigEmailJobSchedule ORDER BY EmailId DESC"
            : "SELECT TOP (@top) * FROM ConfigEmailJobSchedule WHERE Company = @company ORDER BY EmailId DESC";

        var jobs = new List<EmailJob>();

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@top", SqlDbType.Int).Value = top;
        if (!string.IsNullOrWhiteSpace(company))
            cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = company;

        conn.Open();
        using var rdr = cmd.ExecuteReader();
        while (rdr.Read())
            jobs.Add(MapJob(rdr));

        return jobs;
    }

    /// <summary>
    /// Spedizione riuscita: aggiorna SentTimeStamp e resetta IsScheduled.
    /// </summary>
    public void MarkJobSent(int emailId)
    {
        const string sql = @"
            UPDATE ConfigEmailJobSchedule
               SET SentTimeStamp = @ts,
                   IsScheduled   = 'N',
                   IsError       = 'N',
                   ErrorMessage  = ''
             WHERE EmailId = @id";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@ts", SqlDbType.DateTime).Value = DateTime.Now;
        cmd.Parameters.Add("@id", SqlDbType.BigInt).Value = emailId;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Spedizione fallita: incrementa RetryCount e salva il messaggio di errore.
    /// </summary>
    public void MarkJobFailed(int emailId, int newRetryCount, string errorMessage)
    {
        const string sql = @"
            UPDATE ConfigEmailJobSchedule
               SET IsError      = 'S',
                   IsScheduled  = 'N',
                   RetryCount   = @retry,
                   ErrorMessage = @err
             WHERE EmailId = @id";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@retry", SqlDbType.Int).Value = newRetryCount;
        cmd.Parameters.Add("@err", SqlDbType.NVarChar).Value = errorMessage;
        cmd.Parameters.Add("@id", SqlDbType.BigInt).Value = emailId;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Raggiunto il numero massimo di tentativi: marca il job come annullato (IsError='A').
    /// </summary>
    public void MarkJobCancelled(int emailId)
    {
        const string sql = @"
            UPDATE ConfigEmailJobSchedule
               SET IsError     = 'A',
                   IsScheduled = 'N'
             WHERE EmailId = @id";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@id", SqlDbType.BigInt).Value = emailId;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Reinvio manuale da Web UI: azzera errori e rimette il job in coda.
    /// </summary>
    public void RequeueJob(int emailId)
    {
        const string sql = @"
            UPDATE ConfigEmailJobSchedule
               SET IsError       = 'N',
                   IsScheduled   = 'N',
                   RetryCount    = 0,
                   ErrorMessage  = '',
                   SentTimeStamp = NULL
             WHERE EmailId = @id";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@id", SqlDbType.BigInt).Value = emailId;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    // -------------------------------------------------------------------------
    // SERVER CONFIG
    // -------------------------------------------------------------------------

    /// <summary>
    /// Legge i parametri SMTP per la company indicata dalla tabella configurabile.
    /// </summary>
    public EmailServerConfig? GetServerConfig(string company, string tableName = "ConfigEmailServer")
    {
        var sql = $"SELECT * FROM {tableName} WHERE company = @company";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = company;
        conn.Open();
        using var rdr = cmd.ExecuteReader();
        if (!rdr.Read()) return null;

        return new EmailServerConfig
        {
            Company = rdr["company"].ToString()!,
            Smtp_Server = rdr["Smtp_Server"].ToString()!,
            Smtp_Port = Convert.ToInt32(rdr["Smtp_Port"]),
            Smtp_Ssl = rdr["Smtp_Ssl"].ToString()!.ToUpper() == "S",
            Smtp_StartTls = rdr["Smtp_StartTls"].ToString()!.ToUpper() == "S",
            Smtp_Auth = rdr["Smtp_Auth"].ToString()!.ToUpper() == "S",
            Smtp_User = rdr["Smtp_User"].ToString()!,
            Smtp_Password = rdr["Smtp_Password"].ToString()!,
            Smtp_Sender = rdr["Smtp_Sender"].ToString()!,
            Smtp_SenderAlias = rdr["Smtp_SenderAlias"].ToString()!,
            IsDeliveryBlocked = rdr["IsDeliveryBlocked"].ToString()!.ToUpper() == "S"
        };
    }

    /// <summary>
    /// Salva i parametri SMTP per la company — INSERT se non esiste, UPDATE se esiste già.
    /// </summary>
    public void SaveServerConfig(EmailServerConfig cfg, string tableName = "ConfigEmailServer")
    {
        var existing = GetServerConfig(cfg.Company, tableName);

        var sql = existing is null
            ? $@"INSERT INTO {tableName}
                 (company, Smtp_Server, Smtp_Port, Smtp_Ssl, Smtp_StartTls,
                  Smtp_Auth, Smtp_User, Smtp_Password, Smtp_Sender, Smtp_SenderAlias,
                  IsDeliveryBlocked)
                 VALUES
                 (@company, @server, @port, @ssl, @tls,
                  @auth, @user, @pwd, @sender, @alias,
                  @blocked)"
            : $@"UPDATE {tableName} SET
                 Smtp_Server=@server, Smtp_Port=@port, Smtp_Ssl=@ssl, Smtp_StartTls=@tls,
                 Smtp_Auth=@auth, Smtp_User=@user, Smtp_Password=@pwd,
                 Smtp_Sender=@sender, Smtp_SenderAlias=@alias,
                 IsDeliveryBlocked=@blocked
                 WHERE company=@company";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = cfg.Company;
        cmd.Parameters.Add("@server", SqlDbType.NVarChar).Value = cfg.Smtp_Server;
        cmd.Parameters.Add("@port", SqlDbType.Int).Value = cfg.Smtp_Port;
        cmd.Parameters.Add("@ssl", SqlDbType.NChar).Value = cfg.Smtp_Ssl ? "S" : "N";
        cmd.Parameters.Add("@tls", SqlDbType.NChar).Value = cfg.Smtp_StartTls ? "S" : "N";
        cmd.Parameters.Add("@auth", SqlDbType.NChar).Value = cfg.Smtp_Auth ? "S" : "N";
        cmd.Parameters.Add("@user", SqlDbType.NVarChar).Value = cfg.Smtp_User;
        cmd.Parameters.Add("@pwd", SqlDbType.NVarChar).Value = cfg.Smtp_Password;
        cmd.Parameters.Add("@sender", SqlDbType.NVarChar).Value = cfg.Smtp_Sender;
        cmd.Parameters.Add("@alias", SqlDbType.NVarChar).Value = cfg.Smtp_SenderAlias;
        cmd.Parameters.Add("@blocked", SqlDbType.NChar).Value = cfg.IsDeliveryBlocked ? "S" : "N";
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Legge il flag IsDeliveryBlocked dalla tabella ConfigEmailServer per la company indicata.
    /// </summary>
    public bool GetIsDeliveryBlocked(string company, string tableName = "ConfigEmailServer")
    {
        var sql = $"SELECT IsDeliveryBlocked FROM {tableName} WHERE company = @company";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = company;
        conn.Open();
        var result = cmd.ExecuteScalar();
        return result?.ToString()?.ToUpper() == "S";
    }

    /// <summary>
    /// Imposta il flag IsDeliveryBlocked sulla tabella ConfigEmailServer per la company indicata.
    /// </summary>
    public void SetIsDeliveryBlocked(string company, bool blocked, string tableName = "ConfigEmailServer")
    {
        var sql = $"UPDATE {tableName} SET IsDeliveryBlocked = @blocked WHERE company = @company";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@blocked", SqlDbType.NChar).Value = blocked ? "S" : "N";
        cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = company;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    // -------------------------------------------------------------------------
    // LOG
    // -------------------------------------------------------------------------

    public List<LogEntry> GetRecentLogs(int top = 200)
    {
        var sql = $"SELECT TOP (@top) * FROM log ORDER BY Id DESC";
        var logs = new List<LogEntry>();

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@top", SqlDbType.Int).Value = top;
        conn.Open();
        using var rdr = cmd.ExecuteReader();
        while (rdr.Read())
        {
            logs.Add(new LogEntry
            {
                Id = rdr["Id"] == DBNull.Value ? 0 : Convert.ToInt32(rdr["Id"]),
                Company = rdr["company"].ToString()!,
                Data = rdr["data"].ToString()!,
                Ora = rdr["ora"].ToString()!,
                Tipo = rdr["tipo"].ToString()!,
                Operazione = rdr["operazione"].ToString()!,
                Descr = rdr["descr"].ToString()!
            });
        }
        return logs;
    }

    public void WriteLog(string company, string operazione, string descr, string tipo)
    {
        const string sql = @"
            INSERT INTO log (company, data, ora, tipo, operazione, descr)
            VALUES (@company, @data, @ora, @tipo, @operazione, @descr)";

        using var conn = new SqlConnection(_connStr);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.Add("@company", SqlDbType.NVarChar).Value = company;
        cmd.Parameters.Add("@data", SqlDbType.NVarChar).Value = DateTime.Now.ToString("yyyy-MM-dd");
        cmd.Parameters.Add("@ora", SqlDbType.NVarChar).Value = DateTime.Now.ToString("HH:mm:ss");
        cmd.Parameters.Add("@tipo", SqlDbType.NVarChar).Value = tipo;
        cmd.Parameters.Add("@operazione", SqlDbType.NVarChar).Value = operazione;
        cmd.Parameters.Add("@descr", SqlDbType.NVarChar).Value = descr;
        conn.Open();
        cmd.ExecuteNonQuery();
    }

    // -------------------------------------------------------------------------
    // HELPER PRIVATO
    // -------------------------------------------------------------------------

    private static EmailJob MapJob(SqlDataReader rdr) => new()
    {
        EmailId = Convert.ToInt32(rdr["EmailId"]),
        Company = rdr["Company"].ToString()!,
        JobReference = rdr["JobReference"].ToString()!,
        EmailType = rdr["EmailType"].ToString()!,
        EmailBodyIsHtml = rdr["EmailBodyIsHtml"].ToString() == "S",
        EmailObject = rdr["EmailObject"].ToString()!,
        EmailBody = rdr["EmailBody"].ToString()!,
        EmailTo = rdr["EmailTo"].ToString()!,
        EmailCC = rdr["EmailCC"].ToString()!,
        EmailCCN = rdr["EmailCCN"].ToString()!,
        EmailAttachments = rdr["EmailAttachments"].ToString()!,
        CreationTimeStamp = rdr["CreationTimeStamp"] == DBNull.Value ? null : Convert.ToDateTime(rdr["CreationTimeStamp"]),
        SentTimeStamp = rdr["SentTimeStamp"] == DBNull.Value ? null : Convert.ToDateTime(rdr["SentTimeStamp"]),
        IsError = rdr["IsError"].ToString()!,
        ErrorMessage = rdr["ErrorMessage"].ToString()!,
        RetryCount = rdr["RetryCount"] == DBNull.Value ? 0 : Convert.ToInt32(rdr["RetryCount"]),
        IsScheduled = rdr["IsScheduled"].ToString()!
    };
}