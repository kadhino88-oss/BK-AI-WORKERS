using System;
using System.IO;
using System.Net;
using System.Text;
using System.Diagnostics;

class SovereignBridge {
    static void Main() {
        string port = "8080";
        HttpListener listener = new HttpListener();
        listener.Prefixes.Add($"http://*:{port}/");
        try {
            listener.Start();
            Console.WriteLine("==================================================");
            Console.WriteLine($"[BK-AI-WORKERS] Pont souverain actif sur le port {port}");
            Console.WriteLine("[BK-AI-WORKERS] En attente des requetes de Make & du site...");
            Console.WriteLine("==================================================");
        } catch (Exception ex) {
            Console.WriteLine($"Erreur : {ex.Message}");
            return;
        }

        while (true) {
            HttpListenerContext context = listener.GetContext();
            HttpListenerResponse response = context.Response;

            string psScriptPath = "C:\\Users\\FEUCOM\\BK-AI-WORKERS\\core\\runtime\\worker-runtime\\Invoke-Worker-AI.ps1";
            string arguments = "-WorkerId \"alex\" -TaskId \"TASK-WEB-01\" -Objective \"Rediger un livrable pour une fiduciaire genevoise.\" -ClientPlan \"WORKER_SOLO\" -ComputeMode \"FLASH\"";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{psScriptPath}\" {arguments}";
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.StandardOutputEncoding = Encoding.UTF8;

            string output = "";
            try {
                using (Process process = Process.Start(psi)) {
                    output = process.StandardOutput.ReadToEnd();
                    process.WaitForExit();
                }
            } catch (Exception ex) {
                output = "{\"Status\": \"ERROR\", \"Answer\": \"" + ex.Message + "\"}";
            }

            byte[] buffer = Encoding.UTF8.GetBytes(output);
            response.ContentType = "application/json; charset=utf-8";
            response.ContentLength64 = buffer.Length;
            response.OutputStream.Write(buffer, 0, buffer.Length);
            response.OutputStream.Close();
            Console.WriteLine("[requete traitee et transmise avec succes]");
        }
    }
}
