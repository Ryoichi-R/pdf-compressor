// Copyright (c) 2026 Ryoichi-R
// Licensed under the MIT License.
// See LICENSE in the repository root for the full license text.

using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace PdfCompressor.Launcher;

internal static class Program
{
    private const string ProductId = "pdf-compressor";

    [STAThread]
    private static int Main(string[] args)
    {
        var diagnosticsMode = args.Length >= 1 &&
            string.Equals(args[0], "--diagnostics", StringComparison.OrdinalIgnoreCase);
        FileStream? lease = null;
        Mutex? updateGate = null;
        try
        {
            var installRoot = Path.GetFullPath(AppContext.BaseDirectory)
                .TrimEnd(Path.DirectorySeparatorChar);
            ValidateInstallRoot(installRoot);

            var pwsh = RequireManagedFile(installRoot, @"runtime\pwsh\pwsh.exe");
            var diagnosticsOutput = diagnosticsMode && args.Length == 2
                ? Path.GetFullPath(args[1])
                : null;
            var entryScript = RequireManagedFile(
                installRoot,
                diagnosticsMode ? @"_internal\diagnostics.ps1" : @"_internal\gui.ps1");
            var installHash = GetInstallPathHash(installRoot);
            var stateRoot = GetFixedStateRoot(installHash);
            Directory.CreateDirectory(stateRoot);

            updateGate = new Mutex(false, $@"Local\PdfCompressor-Update-{installHash}");
            if (!updateGate.WaitOne(0))
            {
                ShowError("PDF Compressor は更新中です。更新完了後に再実行してください。");
                return 8;
            }

            try
            {
                var leasePath = Path.Combine(
                    stateRoot,
                    $"lease-{Environment.ProcessId}-{Guid.NewGuid():N}.lock");
                lease = new FileStream(
                    leasePath,
                    FileMode.CreateNew,
                    FileAccess.ReadWrite,
                    FileShare.Read,
                    4096,
                    FileOptions.DeleteOnClose);
                var binding = Encoding.UTF8.GetBytes($"{installHash}\n{Environment.ProcessId}\n");
                lease.Write(binding);
                lease.Flush(true);
            }
            finally
            {
                updateGate.ReleaseMutex();
                updateGate.Dispose();
                updateGate = null;
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = pwsh,
                WorkingDirectory = installRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            if (!diagnosticsMode)
            {
                startInfo.ArgumentList.Add("-STA");
            }
            startInfo.ArgumentList.Add("-NoProfile");
            startInfo.ArgumentList.Add("-ExecutionPolicy");
            startInfo.ArgumentList.Add("Bypass");
            startInfo.ArgumentList.Add("-File");
            startInfo.ArgumentList.Add(entryScript);
            if (diagnosticsMode)
            {
                startInfo.ArgumentList.Add("-JsonOnly");
                if (diagnosticsOutput is not null)
                {
                    if (!diagnosticsOutput.StartsWith(installRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException("診断出力はインストール先配下へ保存してください。");
                    }
                    startInfo.ArgumentList.Add("-OutputPath");
                    startInfo.ArgumentList.Add(diagnosticsOutput);
                }
            }
            startInfo.Environment["PDF_COMPRESSOR_INSTALL_ROOT"] = installRoot;
            startInfo.Environment["PDF_COMPRESSOR_PWSH"] = pwsh;
            startInfo.Environment["PDF_COMPRESSOR_BUILD_ID"] = GetBuildId();

            using var child = Process.Start(startInfo)
                ?? throw new InvalidOperationException("PowerShell process could not be started.");
            child.WaitForExit();
            return child.ExitCode;
        }
        catch (Exception ex)
        {
            if (diagnosticsMode)
            {
                Console.Error.WriteLine(ex);
                return 1;
            }
            ShowError($"PDF Compressor を起動できませんでした。\n\n{ex.Message}");
            return 1;
        }
        finally
        {
            lease?.Dispose();
            if (updateGate is not null)
            {
                try
                {
                    updateGate.ReleaseMutex();
                }
                catch (ApplicationException)
                {
                    // The current process did not acquire the mutex.
                }
                updateGate.Dispose();
            }
        }
    }

    private static string RequireManagedFile(string root, string relativePath)
    {
        var path = Path.GetFullPath(Path.Combine(root, relativePath));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(path))
        {
            throw new FileNotFoundException($"必須ファイルが見つかりません: {relativePath}");
        }
        return path;
    }

    private static void ValidateInstallRoot(string root)
    {
        if (root.StartsWith(@"\\", StringComparison.Ordinal) ||
            root.StartsWith(@"\\?\", StringComparison.Ordinal) ||
            root.StartsWith(@"\\.\", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("UNC・device path上からは起動できません。");
        }

        for (var current = new DirectoryInfo(root); current is not null; current = current.Parent)
        {
            if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException(
                    $"reparse point配下からは起動できません: {current.FullName}");
            }
        }
    }

    private static string GetInstallPathHash(string root)
    {
        var normalized = root.ToUpperInvariant();
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)))[..24];
    }

    private static string GetFixedStateRoot(string installHash)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("LocalAppDataを解決できません。");
        }
        return Path.Combine(localAppData, ProductId, "runtime-state", installHash);
    }

    private static string GetBuildId()
    {
        return Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion ?? "unknown";
    }

    private static void ShowError(string message)
    {
        System.Windows.Forms.MessageBox.Show(
            message,
            "PDF Compressor",
            System.Windows.Forms.MessageBoxButtons.OK,
            System.Windows.Forms.MessageBoxIcon.Error);
    }
}
