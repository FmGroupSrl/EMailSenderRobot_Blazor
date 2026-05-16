using EMailSender.Core.Data;
using EMailSender.Core.Services;

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory   // << forza la root alla cartella dell'exe
});

builder.Host.UseWindowsService();

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

var appSettingsPath = Path.Combine(AppContext.BaseDirectory, "appsettings.json");

builder.Services.AddSingleton(new ConfigService(appSettingsPath));
builder.Services.AddSingleton<IConfiguration>(builder.Configuration);
builder.Services.AddScoped<TenantService>();

var app = builder.Build();

app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<EMailSender.Web.Components.App>()
    .AddInteractiveServerRenderMode();

app.Run();