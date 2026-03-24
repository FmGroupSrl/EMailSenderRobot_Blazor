
using EMailSender.Core.Data;
using EMailSender.Core.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Percorso appsettings.json condiviso con l'EXE
var appSettingsPath = Path.Combine(AppContext.BaseDirectory, "appsettings.json");

builder.Services.AddSingleton(new ConfigService(appSettingsPath));
builder.Services.AddSingleton<IConfiguration>(builder.Configuration);

var app = builder.Build();

app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<EMailSender.Web.Components.App>()
    .AddInteractiveServerRenderMode();

app.Run();