using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

static class CliThuVeo
{
    static string Arg(string[] args, string key)
    {
        int at = Array.IndexOf(args, key);
        return at < 0 || at + 1 == args.Length ? "" : args[at + 1];
    }

    static int Main(string[] args)
    {
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        string cwd = AppDomain.CurrentDomain.BaseDirectory;
        string provider = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location);
        bool codex = provider == "codex";
        if (!codex && provider != "agy") return 2;
        if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("OPENAI_API_KEY")) ||
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("GEMINI_API_KEY"))) return 3;
        if (codex && String.Join(" ", args) == "login status")
        {
            if (File.Exists(Path.Combine(cwd, "het-phien-codex")))
            {
                Console.Error.WriteLine("Not logged in");
                return 1;
            }
            Console.WriteLine("Logged in using ChatGPT");
            return 0;
        }
        if (!codex && args.Contains("models"))
        {
            Console.WriteLine("gemini-qa-cut-high\tGemini QA");
            return 0;
        }
        bool direct = codex
            ? args.Length > 0 && args[0] == "exec" && args.Contains("--ignore-user-config") && Arg(args, "--sandbox") == "read-only"
            : Arg(args, "--input-format") == "stream-json" && Arg(args, "--output-format") == "stream-json"
                && Arg(args, "--settings").Contains("mcp(*)") && !args.Contains("--effort");
        string model = Arg(args, "--model");
        if (!direct || model != (codex ? "gpt-qa-cut" : "gemini-qa-cut-high")) return 4;
        string schema = Arg(args, codex ? "--output-schema" : "--json-schema");
        if (!Path.IsPathRooted(schema) || !File.ReadAllText(schema).Contains("\"result\"")) return 5;
        var json = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 };
        string input = Console.In.ReadToEnd();
        string prompt = input;
        if (!codex)
        {
            var message = (Dictionary<string, object>)json.DeserializeObject(input);
            if ((string)message["event"] != "user") return 6;
            prompt = (string)((Dictionary<string, object>)message["message"])["content"];
        }
        string request = codex ? "Bỏ đoạn đỏ từ giây 0 đến 2." : "Bỏ đoạn xanh lam từ giây 4 đến 6 của clip nguồn.";
        if (!prompt.Contains("YÊU CẦU CỦA NGƯỜI DỰNG: " + request)) return 7;
        Match source = Regex.Match(prompt, @"^[^\r\n\t]+\t([A-Za-z0-9_-]+)\t\d+\.\d+–\d+\.\d+\t(?:giữ|BỎ)", RegexOptions.Multiline);
        if (!source.Success) return 8;
        string reply = codex ? "Đã bỏ đoạn đỏ đầu video." : "Đã bỏ đoạn xanh lam cuối video.";
        string id = source.Groups[1].Value;
        int from = codex ? 0 : 4;
        int to = codex ? 2 : 6;
        var step = new { ten = "cutRange", tham_so = new object[] { id, from, to } };
        var wrapped = new { result = json.Serialize(new { tra_loi = reply, viec = new[] { step } }) };
        File.AppendAllText(Path.Combine(cwd, "luot-cli.jsonl"),
            json.Serialize(new { provider, model, direct, from, to, request }) + "\n", new UTF8Encoding(false));
        if (codex)
            File.WriteAllText(Arg(args, "--output-last-message"), json.Serialize(wrapped), new UTF8Encoding(false));
        else
            Console.WriteLine(json.Serialize(new { @event = "result", result = new { status = "SUCCESS", structured_output = wrapped } }));
        return 0;
    }
}
