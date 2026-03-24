using EMailSender.Core.Models;
using MailKit.Net.Smtp;
using MailKit.Security;
using MimeKit;
using MimeKit.Cryptography;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.OpenSsl;

namespace EMailSender.Core.Services;

/// <summary>
/// Servizio di spedizione mail — nessuna dipendenza da ASP.NET/HttpContext.
/// Usato sia dall'EXE Console che dalla Web UI (per il reinvio manuale).
/// 
/// Uso base:
///   var svc = new MailSenderService();
///   svc.SetServerConfig(serverConfig);       // parametri SMTP dal DB
///   svc.SetDkimConfig(dkimConfig);           // parametri DKIM dall'appsettings
///   svc.TO  = new[] { "dest@example.com" };
///   svc.EmailObject  = "Oggetto";
///   svc.EmailFullBody = "Corpo";
///   bool hasError = svc.SendEmail(isHtml: true);
/// </summary>
public class MailSenderService
{
    // --- indirizzi ---
    public string[] TO { get; set; } = [];
    public string[] CC { get; set; } = [];
    public string[] BCC { get; set; } = [];
    public string[] Attachments { get; set; } = [];

    // --- contenuto ---
    public string EmailObject { get; set; } = "";
    public string EmailFullBody { get; set; } = "";

    // --- stato ---
    public bool IsError { get; private set; }
    public string ErrorMessage { get; private set; } = "";

    // --- configurazione (impostata dall'esterno) ---
    private EmailServerConfig? _server;
    private DkimConfig? _dkim;

    public void SetServerConfig(EmailServerConfig cfg) => _server = cfg;
    public void SetDkimConfig(DkimConfig? cfg) => _dkim = cfg;

    /// <summary>
    /// Spedisce la mail. Ritorna true se c'è stato un errore (coerente con il codice originale).
    /// </summary>
    public bool SendEmail(bool isHtml = false, int attempts = 2)
    {
        IsError = false;
        ErrorMessage = "";

        if (_server is null)
        {
            IsError = true;
            ErrorMessage = "Servizio email non configurato - Impossibile spedire un messaggio";
            return true;
        }

        var message = BuildMessage(isHtml);

        // Firma DKIM se configurata
        if (_dkim is not null && !string.IsNullOrWhiteSpace(_dkim.PrivateKeyBase64))
            SignWithDkim(message);

        using var client = new SmtpClient();

        try
        {
            ConnectSmtp(client);

            while (attempts > 0)
            {
                attempts--;
                client.Send(message);
                client.Disconnect(true);
                attempts = 0; // successo: esci dal loop
            }
        }
        catch (Exception ex)
        {
            IsError = true;
            ErrorMessage = ex.Message;
        }

        return IsError;
    }

    // -------------------------------------------------------------------------
    // PRIVATI
    // -------------------------------------------------------------------------

    private MimeMessage BuildMessage(bool isHtml)
    {
        var msg = new MimeMessage();
        msg.From.Add(new MailboxAddress(_server!.Smtp_SenderAlias, _server.Smtp_Sender));

        foreach (var addr in TO)
            if (!string.IsNullOrWhiteSpace(addr))
                msg.To.Add(new MailboxAddress("", addr.Trim()));

        foreach (var addr in CC)
            if (!string.IsNullOrWhiteSpace(addr))
                msg.Cc.Add(new MailboxAddress("", addr.Trim()));

        foreach (var addr in BCC)
            if (!string.IsNullOrWhiteSpace(addr))
                msg.Bcc.Add(new MailboxAddress("", addr.Trim()));

        msg.Subject = EmailObject;

        var builder = new BodyBuilder();
        if (isHtml)
            builder.HtmlBody = EmailFullBody;
        else
            builder.TextBody = EmailFullBody;

        foreach (var path in Attachments)
            if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
                builder.Attachments.Add(path);

        msg.Body = builder.ToMessageBody();
        return msg;
    }

    private void ConnectSmtp(SmtpClient client)
    {
        var s = _server!;

        if (s.Smtp_StartTls)
            client.Connect(s.Smtp_Server, s.Smtp_Port, SecureSocketOptions.StartTls);
        else if (s.Smtp_Ssl)
            client.Connect(s.Smtp_Server, s.Smtp_Port, s.Smtp_Auth);
        else
            client.Connect(s.Smtp_Server, s.Smtp_Port, false);

        if (s.Smtp_Auth)
            client.Authenticate(s.Smtp_User, s.Smtp_Password);
    }

    private void SignWithDkim(MimeMessage message)
    {
        try
        {
            // Decodifica la chiave privata RSA da Base64 → PEM → BouncyCastle
            var keyBytes = Convert.FromBase64String(_dkim!.PrivateKeyBase64);
            var pemString = System.Text.Encoding.ASCII.GetString(keyBytes);

            AsymmetricKeyParameter privateKey;
            using (var reader = new StringReader(pemString))
            {
                var pemReader = new PemReader(reader);
                var keyPair = pemReader.ReadObject() as AsymmetricCipherKeyPair
                                ?? throw new InvalidOperationException("Chiave DKIM non valida");
                privateKey = keyPair.Private;
            }

            var signer = new DkimSigner(privateKey, _dkim.Domain, _dkim.Selector)
            {
                HeaderCanonicalizationAlgorithm = DkimCanonicalizationAlgorithm.Simple,
                BodyCanonicalizationAlgorithm = DkimCanonicalizationAlgorithm.Simple,
                AgentOrUserIdentifier = $"@{_dkim.Domain}",
            };

            // Header da firmare (quelli standard raccomandati)
            var headersToSign = new[]
            {
                HeaderId.From,
                HeaderId.Subject,
                HeaderId.Date,
                HeaderId.MessageId
            };

            signer.Sign(message, headersToSign);
        }
        catch (Exception ex)
        {
            // La firma DKIM è opzionale: se fallisce logghiamo ma non blocchiamo la spedizione
            ErrorMessage += $" [DKIM warning: {ex.Message}]";
        }
    }

    /// <summary>
    /// Ritorna un riepilogo testuale dei parametri server (utile per il log degli errori).
    /// </summary>
    public string GetServerDetails()
    {
        if (_server is null) return "Server non configurato";
        var s = _server;
        return $"Server: {s.Smtp_Server}:{s.Smtp_Port} | SSL:{s.Smtp_Ssl} | TLS:{s.Smtp_StartTls} | Auth:{s.Smtp_Auth} | User:{s.Smtp_User} | Sender:{s.Smtp_Sender}";
    }
}