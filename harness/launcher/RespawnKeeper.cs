// ============================================================
// RespawnKeeper.cs - the double-clickable front door.
//
// This is a SHELL and nothing else. It knows exactly one thing, and that thing
// is about windows, not about behaviour:
//
//     no arguments -> whatever runs needs no console   (the panel is a GUI)
//     an argument  -> whatever runs needs a console    (the wizard is a console
//                                                       program, and this exe is
//                                                       /target:winexe so it has
//                                                       none of its own to lend)
//
// WHAT IT DELIBERATELY NO LONGER KNOWS (2026-09-13, [R-080])
//
// It used to also decide WHICH script to run - panel here, wizard there. That
// same rule was written again in respawnkeeper.bat and again in panel.bat, in
// cmd, and the copies had drifted: double-clicking the exe opened the panel
// while double-clicking the bat opened the wizard. Two front doors with one
// name and two behaviours.
//
// Worse than the confusion was the maintenance shape. The -WindowStyle Hidden
// defect in [R-077] - a hide REQUEST that Windows Terminal ignores, leaving an
// empty console window on the desktop - was present in every copy and had to be
// found and fixed in each one separately.
//
// So the routing moved to harness\rk-entry.ps1 and this file forwards to it.
// Anything this exe is asked to do that is new belongs THERE. If you find
// yourself adding an "if" to this file about what respawnkeeper should do, that
// is the mistake this comment exists to stop.
//
// Built by build-exe.ps1 with the csc.exe that ships inside Windows, so nothing
// is downloaded and the source sits next to the binary for anyone to read.
// ============================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class RespawnKeeper
{
    private const string EntryRelativePath = @"harness\rk-entry.ps1";

    [STAThread]
    private static int Main(string[] args)
    {
        // Resolve from the assembly location, never the working directory:
        // Explorer hands a double-clicked program whatever directory it likes,
        // and a drag-and-drop gives it the dragged folder's parent.
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string entry  = Path.Combine(exeDir, EntryRelativePath);

        if (!File.Exists(entry))
        {
            Fail("respawnkeeper\n\n"
               + "Cannot find:\n  " + entry + "\n\n"
               + "This exe has to stay in the respawnkeeper folder, next to harness\\.\n"
               + "Move it back, or make a SHORTCUT to it instead of copying it.");
            return 2;
        }

        // One optional argument. Anything past the first is ignored rather than
        // guessed at: dropping five folders at once is a mistake, not a batch
        // job, and one run of the wizard handles exactly one server.
        bool console = (args.Length > 0 && !string.IsNullOrEmpty(args[0]));

        StringBuilder psArgs = new StringBuilder();
        psArgs.Append("-NoProfile -STA -ExecutionPolicy Bypass -File \"").Append(entry).Append('"');
        if (console)
        {
            psArgs.Append(" \"").Append(args[0].TrimEnd('"')).Append('"');
        }

        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", psArgs.ToString());
        psi.WorkingDirectory = exeDir;
        if (console)
        {
            psi.UseShellExecute = true;      // give the console program its own console
        }
        else
        {
            // CreateNoWindow, not a -WindowStyle Hidden hint: this becomes
            // CREATE_NO_WINDOW on the CreateProcess call, so no console is
            // allocated and no terminal gets a say ([R-077]).
            psi.UseShellExecute = false;
            psi.CreateNoWindow  = true;
        }

        try
        {
            Process p = Process.Start(psi);
            // The wizard is interactive and owns the operator's attention until
            // it finishes, so wait and surface a bad exit. The panel is a window
            // they close when they feel like it - waiting on that would leave
            // this process alive for hours for no reason.
            if (console)
            {
                p.WaitForExit();
                return p.ExitCode;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Fail("respawnkeeper\n\nCould not start powershell.exe:\n" + ex.Message);
            return 3;
        }
    }

    private static void Fail(string message)
    {
        // /target:winexe means there is no console to print to. A silent exit
        // would be indistinguishable from "nothing happened when I clicked it".
        MessageBox.Show(message, "respawnkeeper", MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
