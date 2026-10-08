// CrashSim - a stand-in for a Minecraft dedicated server, used by
// tests\Invoke-SelfTest.ps1 to prove the crash -> diagnose -> repair -> restart
// loop end to end WITHOUT touching a real server or a real world.
//
// It is launched by respawnkeeper.ps1 exactly the way a real server is:
//     java @user_jvm_args.txt @libraries/.../win_args.txt nogui
// so the launch path being exercised (java resolution, argfiles, working
// directory, stdin pipe, exit code, crash-report timing) is the real one.
//
// Behaviour is chosen by a one-word control file, crashsim.mode, in the server
// folder. Missing file = "trigger".
//
//   trigger : if mods\<TRIGGER_JAR> is present -> write a crash report, exit 1
//             otherwise                        -> print Done, exit 0
//             So the repair (quarantining that jar) is what actually makes the
//             next boot succeed. Nothing about the outcome is faked.
//   kill    : exit non-zero with NO crash report, NO hs_err, NO exception in
//             the log - i.e. exactly what killing java from Task Manager looks
//             like from the outside. respawnkeeper must NOT call this a crash.
//   clean   : write the vanilla shutdown sequence to the log, then exit 0.
//   serve   : stay up until "stop" arrives on stdin or STOP_SERVER appears,
//             then shut down cleanly. The only mode that is still running when
//             the daily maintenance cycle fires.
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

public class CrashSim {
    private static final String TRIGGER_JAR = "Structory_Towers_26.2_v1.0.17.jar";

    public static void main(String[] args) throws IOException, InterruptedException {
        Path cwd = Paths.get("").toAbsolutePath();
        Path logs = cwd.resolve("logs");
        Files.createDirectories(logs);
        Path trigger = cwd.resolve("mods").resolve(TRIGGER_JAR);

        System.out.println("[CrashSim] starting in " + cwd);
        appendLog(logs.resolve("latest.log"), "[CrashSim] starting");

        String mode = "trigger";
        Path modeFile = cwd.resolve("crashsim.mode");
        if (Files.exists(modeFile)) {
            mode = Files.readString(modeFile, StandardCharsets.UTF_8).trim().toLowerCase();
        }
        System.out.println("[CrashSim] mode = " + mode);

        // A real server takes a moment to boot; give the harness something to see.
        Thread.sleep(1500);

        if (mode.equals("kill")) {
            // No crash report, no hs_err, no stack trace - only a non-zero exit.
            appendLog(logs.resolve("latest.log"), "[CrashSim] terminated externally, exiting 137");
            System.out.println("[CrashSim] simulating an external kill (exit 137, no evidence).");
            System.exit(137);
        }

        // "serve" is the only mode that stays alive. It exists for the daily
        // maintenance test: a maintenance cycle stops a RUNNING server, so
        // every other mode (which exits within seconds) would be finished
        // before the cycle ever fired.
        //
        // It answers the two things the supervisor uses to take a server down:
        // the word "stop" on stdin (the minecraft template's stop plan) and the
        // STOP_SERVER flag file that rk-stop.bat drops. It also keeps
        // logs/latest.log moving so the hang heuristic stays quiet.
        if (mode.equals("serve")) {
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: Done (1.234s)! For help, type \"help\"");
            System.out.println("[CrashSim] serving; write 'stop' on stdin or create STOP_SERVER.");
            BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            Path stopFlag = cwd.resolve("STOP_SERVER");
            long deadline = System.currentTimeMillis() + (10 * 60 * 1000);   // never run away
            while (System.currentTimeMillis() < deadline) {
                if (in.ready()) {
                    String line = in.readLine();
                    if (line == null) break;
                    if (line.trim().equalsIgnoreCase("stop")) { break; }
                    System.out.println("[CrashSim] console: " + line.trim());
                }
                if (Files.exists(stopFlag)) { break; }
                appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: tick");
                Thread.sleep(500);
            }
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: Stopping the server");
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: Saving worlds");
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: ThreadedAnvilChunkStorage: All dimensions are saved");
            System.out.println("[CrashSim] stopped cleanly (exit 0).");
            System.exit(0);
        }

        if (mode.equals("clean")) {
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: Stopping the server");
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: Saving worlds");
            appendLog(logs.resolve("latest.log"), "[Server thread/INFO]: ThreadedAnvilChunkStorage: All dimensions are saved");
            System.out.println("[CrashSim] simulating a clean shutdown (exit 0).");
            System.exit(0);
        }

        if (Files.exists(trigger)) {
            Path dir = cwd.resolve("crash-reports");
            Files.createDirectories(dir);
            String stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy-MM-dd_HH.mm.ss"));
            Path report = dir.resolve("crash-" + stamp + "-fml.txt");
            try (PrintWriter w = new PrintWriter(Files.newBufferedWriter(report, StandardCharsets.UTF_8))) {
                w.println("---- Minecraft Crash Report ----");
                w.println("// CrashSim: this is a synthetic report written by the respawnkeeper self-test.");
                w.println();
                w.println("Time: " + LocalDateTime.now());
                w.println("Description: Mod loading failures have occurred; consult the issue messages for more details");
                w.println();
                w.println("net.neoforged.neoforge.logging.CrashReportExtender$ModLoadingCrashException: Mod loading has failed");
                w.println();
                w.println("\tFailure message: File " + trigger + " is not a valid mod file");
                w.println("\tMod File: " + trigger);
            }
            appendLog(logs.resolve("latest.log"), "[CrashSim] wrote " + report.getFileName() + ", exiting 1");
            System.out.println("[CrashSim] CRASH (trigger jar present): " + report);
            System.exit(1);
        }

        appendLog(logs.resolve("latest.log"), "[CrashSim] Done (no trigger jar), exiting 0");
        System.out.println("[CrashSim] Done - clean exit.");
        System.exit(0);
    }

    private static void appendLog(Path p, String line) throws IOException {
        Files.writeString(p, LocalDateTime.now() + " " + line + System.lineSeparator(),
                StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }
}
