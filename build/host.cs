using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

static class Program {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetDllDirectory(string lpPathName);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool DeleteFile(string lpFileName);
    [DllImport("shell32.dll")]
    static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    static string BaseDir;
    static string LibDir;

    // 깃허브 ZIP 다운로드 시 모든 파일에 붙는 "인터넷에서 받음" 표시(Zone.Identifier / MOTW)를
    // 프로그램 폴더 전체에서 제거한다. 관리형 WebView2 DLL 이 이 표시 때문에 로드 거부되는 것을
    // exe.config(loadFromRemoteSources)와 함께 이중으로 막고, 다음 실행부터 SmartScreen 경고도 사라진다.
    // ADS 삭제라 원본 파일은 그대로. 삭제 실패(권한/읽기전용 매체)는 무시 — config 가 최종 안전망.
    static void UnblockFolder(string dir) {
        try {
            foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) {
                try { DeleteFile(f + ":Zone.Identifier"); } catch {}
            }
        } catch {}
    }

    [STAThread]
    static void Main() {
        BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        LibDir = Path.Combine(BaseDir, "app", "lib");
        // WebView2 어셈블리가 처음 로드(new MainForm())되기 전에 MOTW 표시부터 제거
        UnblockFolder(BaseDir);
        // 네이티브 WebView2Loader.dll 을 app\lib 에서 찾도록
        SetDllDirectory(LibDir);
        // 관리형 WebView2 DLL 도 app\lib 에서 로드
        AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
            string dll = new AssemblyName(e.Name).Name + ".dll";
            string p = Path.Combine(LibDir, dll);
            return File.Exists(p) ? Assembly.LoadFrom(p) : null;
        };
        try { SetCurrentProcessExplicitAppUserModelID("subnautica-kr.cert-migrator"); } catch {}
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}

class MainForm : Form {
    WebView2 web;
    Process server;
    string urlFile;

    public MainForm() {
        Text = "인증서 이사 도우미";
        try { Icon = new System.Drawing.Icon(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app", "ui", "favicon.ico")); } catch {}
        ClientSize = new System.Drawing.Size(1080, 660);
        MinimumSize = new System.Drawing.Size(340, 480);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = System.Drawing.Color.FromArgb(242, 244, 248);
        Load += OnLoad;
        FormClosed += (s, e) => KillServer();
    }

    async void OnLoad(object sender, EventArgs e) {
        string url = null;
        try { url = StartServerAndGetUrl(); }
        catch (Exception ex) { MessageBox.Show("서버 시작 실패: " + ex.Message, "인증서 이사 도우미", MessageBoxButtons.OK, MessageBoxIcon.Error); Close(); return; }
        if (url == null) { MessageBox.Show("프로그램 시작에 실패했습니다.\napp\\main.ps1 을 확인해 주세요.", "인증서 이사 도우미", MessageBoxButtons.OK, MessageBoxIcon.Error); Close(); return; }

        try {
            web = new WebView2();
            web.Dock = DockStyle.Fill;
            Controls.Add(web);
            string userData = Path.Combine(Path.GetTempPath(), "certmig_wv2");
            var env = await CoreWebView2Environment.CreateAsync(null, userData);
            await web.EnsureCoreWebView2Async(env);
            web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            web.CoreWebView2.Settings.IsStatusBarEnabled = false;
            web.CoreWebView2.Navigate(url);
        } catch (Exception ex) {
            // WebView2 실패 시 Edge 앱모드로라도 띄움(최후 수단)
            try {
                foreach (string p in new[] {
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) + "\\Microsoft\\Edge\\Application\\msedge.exe",
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + "\\Microsoft\\Edge\\Application\\msedge.exe" }) {
                    if (File.Exists(p)) { Process.Start(p, "--app=" + url + " --window-size=380,600"); break; }
                }
            } catch {}
            MessageBox.Show("화면 구성 요소(WebView2)를 열지 못해 브라우저로 실행했습니다.\n" + ex.Message, "인증서 이사 도우미", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            Close();
        }
    }

    string StartServerAndGetUrl() {
        string script = Path.Combine(BaseDirOf(), "app", "main.ps1");
        if (!File.Exists(script)) throw new FileNotFoundException("app\\main.ps1 을 찾을 수 없습니다. 폴더를 통째로 복사했는지 확인하세요.");
        urlFile = Path.Combine(Path.GetTempPath(), "certmig_url_" + Guid.NewGuid().ToString("N") + ".txt");
        if (File.Exists(urlFile)) File.Delete(urlFile);

        var psi = new ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File \"" + script + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = BaseDirOf();
        psi.EnvironmentVariables["CERTMIG_URLFILE"] = urlFile;
        server = Process.Start(psi);

        // 서버가 URL 파일을 쓸 때까지 대기 (최대 25초)
        var until = DateTime.Now.AddSeconds(25);
        while (DateTime.Now < until) {
            if (File.Exists(urlFile)) {
                try {
                    string u = File.ReadAllText(urlFile).Trim();
                    if (u.StartsWith("http")) return u;
                } catch {}
            }
            if (server != null && server.HasExited) return null;
            System.Threading.Thread.Sleep(120);
        }
        return null;
    }

    static string BaseDirOf() { return AppDomain.CurrentDomain.BaseDirectory; }

    void KillServer() {
        try { if (server != null && !server.HasExited) server.Kill(); } catch {}
        try { if (urlFile != null && File.Exists(urlFile)) File.Delete(urlFile); } catch {}
    }
}
