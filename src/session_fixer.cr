require "json"
require "file_utils"
require "set"

module SessionFixer
  CLAUDE_DIR = Path.home / ".claude"
  PROJECTS_DIR = CLAUDE_DIR / "projects"

  THINKING_TYPES = Set{"thinking", "redacted_thinking"}

  struct Stats
    property lines_total = 0
    property lines_modified = 0
    property lines_removed = 0
    property thinking_blocks_removed = 0
    property parse_errors = 0
  end

  # Find all .jsonl session files under ~/.claude/projects/
  def self.find_all_sessions : Array(Path)
    results = [] of Path
    return results unless Dir.exists?(PROJECTS_DIR.to_s)

    Dir.each_child(PROJECTS_DIR.to_s) do |project_dir|
      project_path = PROJECTS_DIR / project_dir
      next unless File.directory?(project_path.to_s)
      Dir.each_child(project_path.to_s) do |file|
        next unless file.ends_with?(".jsonl")
        next if /\.bak(\.\d+)?\.jsonl$/.matches?(file)
        results << project_path / file
      end
    end
    results.sort_by! { |p| File.info(p.to_s).modification_time }.reverse!
    results
  end

  def self.expand_home(path : String) : String
    return path unless path.starts_with?("~/")
    "#{Path.home}/#{path[2..]}"
  end

  # Find session file candidates by exact UUID first, then partial UUID
  def self.find_session_candidates(id_or_path : String) : Array(Path)
    # Direct file path
    expanded_path = expand_home(id_or_path)
    if File.exists?(expanded_path) && expanded_path.ends_with?(".jsonl")
      return [Path.new(expanded_path)]
    end

    sessions = find_all_sessions
    exact_matches = sessions.select { |p| p.basename(".jsonl") == id_or_path }
    return exact_matches unless exact_matches.empty?

    sessions.select { |p| p.basename(".jsonl").includes?(id_or_path) }
  end

  # Count thinking blocks in a session (for --list)
  def self.count_thinking_blocks(path : Path) : {Int32, Int32}
    messages_with_thinking = 0
    total_thinking_blocks = 0

    File.each_line(path.to_s) do |line|
      next if line.empty?
      begin
        obj = JSON.parse(line)
        next unless obj["type"]?.try(&.as_s?) == "assistant"
        content = obj.dig?("message", "content")
        next unless content && content.as_a?

        count = content.as_a.count do |block|
          block["type"]?.try(&.as_s?).try { |t| THINKING_TYPES.includes?(t) } || false
        end
        if count > 0
          messages_with_thinking += 1
          total_thinking_blocks += count
        end
      rescue
        next
      end
    end

    {messages_with_thinking, total_thinking_blocks}
  end

  # Process a single JSONL line, returns {modified_line_or_nil, modified, thinking_removed, parse_error}
  def self.process_line(line : String) : {String?, Bool, Int32, Bool}
    return {line, false, 0, false} if line.empty?

    begin
      obj = JSON.parse(line)
    rescue
      return {line, false, 0, true}
    end

    # Only process assistant messages
    return {line, false, 0, false} unless obj["type"]?.try(&.as_s?) == "assistant"

    # Need mutable access to content array
    content = obj.dig?("message", "content")
    return {line, false, 0, false} unless content && content.as_a?

    content_arr = content.as_a
    thinking_count = content_arr.count do |block|
      block["type"]?.try(&.as_s?).try { |t| THINKING_TYPES.includes?(t) } || false
    end

    return {line, false, 0, false} if thinking_count == 0

    # Filter out thinking blocks
    filtered = content_arr.reject do |block|
      block["type"]?.try(&.as_s?).try { |t| THINKING_TYPES.includes?(t) } || false
    end

    # If content becomes empty, skip the entire line
    if filtered.empty?
      return {nil, true, thinking_count, false}
    end

    # Rebuild JSON with filtered content using the already parsed object
    raw = obj.as_h
    message = raw["message"].as_h
    message["content"] = JSON::Any.new(filtered)
    raw["message"] = JSON::Any.new(message)

    {raw.to_json, true, thinking_count, false}
  end

  def self.backup_path_for(path : Path) : Path
    base = path.to_s.sub(/\.jsonl$/, "")
    default_backup = Path.new("#{base}.bak.jsonl")
    return default_backup unless File.exists?(default_backup.to_s)

    Path.new("#{base}.bak.#{Time.utc.to_unix_ms}.jsonl")
  end

  # Fix a session file
  def self.fix_session(path : Path, dry_run : Bool = false) : Stats
    stats = Stats.new
    tmp_path = Path.new(path.to_s + ".tmp")

    output = dry_run ? nil : File.open(tmp_path.to_s, "w")

    begin
      File.each_line(path.to_s) do |line|
        stats.lines_total += 1
        result, modified, thinking_removed, parse_error = process_line(line)
        stats.parse_errors += 1 if parse_error

        if result.nil?
          stats.lines_removed += 1
          stats.thinking_blocks_removed += thinking_removed
          next
        end

        if modified
          stats.lines_modified += 1
          stats.thinking_blocks_removed += thinking_removed
        end

        output.try &.puts(result)
      end
    ensure
      output.try &.close
    end

    unless dry_run
      if stats.lines_modified > 0 || stats.lines_removed > 0
        bak_path = backup_path_for(path)
        # Backup original
        FileUtils.cp(path.to_s, bak_path.to_s)
        # Replace with fixed version
        File.rename(tmp_path.to_s, path.to_s)
        STDERR.puts "Backup saved to: #{bak_path}"
      else
        # No changes needed, remove temp file
        File.delete(tmp_path.to_s) if File.exists?(tmp_path.to_s)
      end
    end

    stats
  end

  def self.list_sessions
    sessions = find_all_sessions

    if sessions.empty?
      puts "No sessions found in #{PROJECTS_DIR}"
      return
    end

    puts "Sessions with thinking blocks:\n"
    puts "%-40s %-40s %5s %7s %10s" % {"Session ID", "Project", "Msgs", "Blocks", "Size"}
    puts "-" * 105

    sessions.each do |path|
      session_id = path.basename(".jsonl")
      project = path.parent.basename
      msgs, blocks = count_thinking_blocks(path)
      next if blocks == 0
      size = File.size(path.to_s)
      size_str = if size > 1_000_000
                   "#{(size / 1_000_000.0).round(1)} MB"
                 elsif size > 1_000
                   "#{(size / 1_000.0).round(1)} KB"
                 else
                   "#{size} B"
                 end
      puts "%-40s %-40s %5d %7d %10s" % {session_id, project, msgs, blocks, size_str}
    end
  end

  def self.run(args : Array(String))
    if args.empty? || args.includes?("--help") || args.includes?("-h")
      STDERR.puts <<-USAGE
      Claude Code Session Fixer

      Fixes sessions broken by modified thinking/redacted_thinking blocks.

      Usage:
        session_fixer <session-id>          Fix a session (full or partial UUID)
        session_fixer <path-to-jsonl>       Fix a session file directly
        session_fixer <session-id> --dry-run Show what would be changed
        session_fixer --list                List sessions with thinking blocks

      The tool removes thinking/redacted_thinking blocks from assistant messages
      in the session JSONL file. A backup (.bak.jsonl or .bak.<ts>.jsonl) is created before modifying.
      USAGE
      exit(args.empty? ? 1 : 0)
    end

    if args.includes?("--list")
      list_sessions
      return
    end

    dry_run = args.includes?("--dry-run")
    session_arg = args.reject { |a| a.starts_with?("--") }.first?

    unless session_arg
      STDERR.puts "Error: No session ID or file path provided."
      exit(1)
    end

    matches = find_session_candidates(session_arg)
    if matches.empty?
      STDERR.puts "Error: Session '#{session_arg}' not found."
      STDERR.puts "Use --list to see available sessions."
      exit(1)
    end
    if matches.size > 1
      STDERR.puts "Error: Session '#{session_arg}' is ambiguous (#{matches.size} matches)."
      STDERR.puts "Provide a longer session ID or full path."
      STDERR.puts "Matches:"
      matches.first(10).each do |match|
        STDERR.puts "  - #{match.basename(".jsonl")} (#{match.parent.basename})"
      end
      STDERR.puts "  ... and #{matches.size - 10} more" if matches.size > 10
      exit(1)
    end
    path = matches.first

    puts "Session file: #{path}"
    puts "File size: #{(File.size(path.to_s) / 1_000_000.0).round(1)} MB"
    puts dry_run ? "Mode: DRY RUN (no changes will be made)\n" : "Mode: FIX\n"

    stats = fix_session(path, dry_run)

    puts "Lines total:            #{stats.lines_total}"
    puts "Lines modified:         #{stats.lines_modified}"
    puts "Lines removed (empty):  #{stats.lines_removed}"
    puts "Thinking blocks removed: #{stats.thinking_blocks_removed}"
    puts "Parse errors skipped:   #{stats.parse_errors}" if stats.parse_errors > 0

    if stats.lines_modified == 0 && stats.lines_removed == 0
      puts "\nNo thinking blocks found. Session may have a different issue."
    elsif dry_run
      puts "\nDry run complete. Run without --dry-run to apply changes."
    else
      puts "\nSession fixed. Try resuming with: claude --resume #{path.basename(".jsonl")}"
    end
  end
end

SessionFixer.run(ARGV)
