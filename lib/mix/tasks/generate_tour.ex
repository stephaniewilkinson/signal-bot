defmodule Mix.Tasks.GenerateTour do
  @moduledoc """
  Generates a product tour GIF and MP4 from tour/tour-script.json.

  Renders each step as an SVG frame, converts to PNG via resvg,
  and compiles into tour.gif and tour.mp4 via ffmpeg.

  ## Usage

      mix generate_tour

  ## Requirements

  CLI tools: `resvg`, `ffmpeg`, `gifsicle`
  """

  use Mix.Task

  @shortdoc "Generate product tour GIF and MP4 from tour script"

  @width 420
  @bubble_max_width 320
  @char_width 7.2
  @line_height 18
  @bubble_padding_x 14
  @bubble_padding_y 10
  @header_height 56
  @bubble_gap 6
  @name_height 16
  @fps 4
  @max_height 912
  @max_gif_bytes 5_000_000

  # Cover image dimensions
  @cover_width 80
  @cover_height 120

  # Poll option dimensions
  @option_height 38
  @option_gap 8

  # Colors
  @bg "#1b1c1e"
  @bubble_incoming "#2a2b2e"
  @bubble_outgoing "#2c6bed"
  @text_color "#e9e9e9"
  @name_color "#8e8e93"
  @header_bg "#252628"
  @header_border "#333335"
  @poll_bg "#1f3a6e"
  @typing_dot "#8e8e93"

  @impl Mix.Task
  def run(_args) do
    script_path = Path.join(File.cwd!(), "tour/tour-script.json")
    frames_dir = Path.join(File.cwd!(), "tour/frames")

    script = script_path |> File.read!() |> Jason.decode!()

    # Append an auto-generated help scene from the live formatter
    help_text = YonderbookClubs.Bot.Formatter.format_help() |> String.trim()

    help_scene = %{
      "scene" => "Help",
      "context" => "dm",
      "chatName" => "Yonderbook Clubs",
      "steps" => [
        %{"sender" => "user", "name" => "New Member", "text" => "/help", "pause" => 1500},
        %{"sender" => "bot", "name" => "Yonderbook Clubs", "text" => help_text, "pause" => 3000}
      ]
    }

    script = script ++ [help_scene]

    # Flatten scenes into a list of {scene_meta, accumulated_messages} states
    states = build_states(script)

    File.rm_rf!(frames_dir)
    File.mkdir_p!(frames_dir)

    # Download cover images before calculating heights
    cover_data = download_covers(states, frames_dir)

    # Generate SVG frames: for each state, optionally a typing frame + the message frame
    frame_paths = generate_frames(states, frames_dir, cover_data)

    # Hold the last frame for 3 seconds
    {last_frame, _} = List.last(frame_paths)
    all_frames = frame_paths ++ [{last_frame, 3.0}]

    # Expand variable-duration frames into constant-FPS sequence
    expanded_pngs =
      all_frames
      |> Enum.with_index()
      |> Enum.flat_map(fn {{src_path, duration}, _frame_idx} ->
        copies = max(round(duration * @fps), 1)

        for c <- 1..copies do
          dest = Path.join(frames_dir, "seq_#{String.pad_leading("#{System.unique_integer([:positive])}_#{c}", 10, "0")}.png")
          File.cp!(src_path, dest)
          dest
        end
      end)

    Mix.shell().info("#{length(all_frames)} keyframes -> #{length(expanded_pngs)} frames at #{@fps}fps")

    # Write frame list for ffmpeg
    concat_file = Path.join(frames_dir, "concat.txt")
    frame_duration = 1 / @fps

    concat_content =
      expanded_pngs
      |> Enum.map_join("\n", fn path ->
        "file '#{path}'\nduration #{frame_duration}"
      end)

    File.write!(concat_file, concat_content <> "\n")

    gif_path = Path.join(File.cwd!(), "tour.gif")
    mp4_path = Path.join(File.cwd!(), "tour.mp4")

    # Generate MP4
    Mix.shell().info("Generating tour.mp4...")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", concat_file,
        "-vf", "format=yuv420p",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        mp4_path
      ], stderr_to_stdout: true)

    # Generate GIF via ffmpeg palette method
    Mix.shell().info("Generating tour.gif...")
    palette_path = Path.join(frames_dir, "palette.png")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", concat_file,
        "-vf", "palettegen=max_colors=64:stats_mode=diff",
        palette_path
      ], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", concat_file,
        "-i", palette_path,
        "-lavfi", "[0:v][1:v] paletteuse=dither=bayer:bayer_scale=3",
        gif_path
      ], stderr_to_stdout: true)

    # Optimize with gifsicle if over 5MB
    gif_size = File.stat!(gif_path).size

    if gif_size > @max_gif_bytes do
      Mix.shell().info("GIF is #{div(gif_size, 1024)}KB, optimizing with gifsicle...")

      {_, 0} =
        System.cmd("gifsicle", [
          "--batch",
          "--optimize=3",
          "--lossy=80",
          "--colors", "64",
          gif_path
        ], stderr_to_stdout: true)

      new_size = File.stat!(gif_path).size
      Mix.shell().info("Optimized: #{div(new_size, 1024)}KB")
    end

    # Clean up
    File.rm_rf!(frames_dir)

    gif_size = File.stat!(gif_path).size
    mp4_size = File.stat!(mp4_path).size
    Mix.shell().info("Done! tour.gif (#{div(gif_size, 1024)}KB), tour.mp4 (#{div(mp4_size, 1024)}KB)")
  end

  # --- State Building ---

  defp build_states(script) do
    script
    |> Enum.flat_map(fn scene ->
      meta = %{
        context: scene["context"],
        chat_name: scene["chatName"]
      }

      scene["steps"]
      |> Enum.map(fn step ->
        %{
          sender: step["sender"],
          name: step["name"],
          text: step["text"],
          is_poll: step["isPoll"] == true,
          pause: (step["pause"] || 1500) / 1000,
          covers: step["covers"] || [],
          replaces: step["replaces"] == true,
          context: scene["context"]
        }
      end)
      |> Enum.map(fn step -> {meta, step} end)
    end)
    |> Enum.reduce({[], nil, []}, fn {meta, step}, {acc, prev_meta, messages} ->
      # If scene changed, reset messages
      messages =
        if prev_meta != nil and prev_meta != meta do
          []
        else
          messages
        end

      new_messages =
        if step.replaces do
          List.delete_at(messages, -1) ++ [step]
        else
          messages ++ [step]
        end

      {acc ++ [{meta, new_messages}], meta, new_messages}
    end)
    |> elem(0)
  end

  # --- Cover Downloads ---

  defp download_covers(states, frames_dir) do
    isbns =
      states
      |> Enum.flat_map(fn {_meta, messages} ->
        Enum.flat_map(messages, & &1.covers)
      end)
      |> Enum.uniq()

    if isbns == [] do
      %{}
    else
      covers_dir = Path.join(frames_dir, "covers")
      File.mkdir_p!(covers_dir)
      Mix.shell().info("Downloading #{length(isbns)} cover images...")

      isbns
      |> Enum.map(fn isbn ->
        path = Path.join(covers_dir, "#{isbn}.jpg")

        case System.cmd("curl", ["-sL", "-o", path,
               "https://covers.openlibrary.org/b/isbn/#{isbn}-M.jpg"],
               stderr_to_stdout: true) do
          {_, 0} ->
            data = File.read!(path)
            Mix.shell().info("  #{isbn}: #{div(byte_size(data), 1024)}KB")
            {isbn, "data:image/jpeg;base64," <> Base.encode64(data)}

          _ ->
            Mix.shell().info("  Warning: could not download cover for #{isbn}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    end
  end

  # --- Frame Generation ---

  defp calculate_max_height(states, cover_data) do
    states
    |> Enum.flat_map(fn {_meta, messages} ->
      current_step = List.last(messages)

      heights =
        if current_step.sender == "bot" do
          typing_messages = List.delete_at(messages, -1)
          [calculate_height(typing_messages, cover_data, typing: true)]
        else
          []
        end

      heights ++ [calculate_height(messages, cover_data)]
    end)
    |> Enum.max()
  end

  defp calculate_height(messages, cover_data, opts \\ []) do
    show_typing = Keyword.get(opts, :typing, false)
    {_elements, y_after_bubbles} = render_bubbles(messages, @header_height + 12, cover_data)

    total_y =
      if show_typing do
        {_el, y_after_typing} = render_typing_indicator(y_after_bubbles + @bubble_gap)
        y_after_typing
      else
        y_after_bubbles
      end

    total_y + 20
  end

  defp generate_frames(states, frames_dir, cover_data) do
    max_height = min(calculate_max_height(states, cover_data), @max_height)
    Mix.shell().info("Uniform frame height: #{max_height}px")

    states
    |> Enum.with_index()
    |> Enum.flat_map(fn {{meta, messages}, idx} ->
      prefix = String.pad_leading("#{idx}", 4, "0")
      current_step = List.last(messages)

      frames =
        if current_step.sender == "bot" do
          # Typing indicator frame (brief)
          typing_messages = List.delete_at(messages, -1)
          typing_svg = render_svg(meta, typing_messages, max_height, cover_data, typing: true)
          typing_path = Path.join(frames_dir, "frame_#{prefix}_a.svg")
          typing_png = Path.rootname(typing_path) <> ".png"
          File.write!(typing_path, typing_svg)
          svg_to_png(typing_path, typing_png)
          [{typing_png, 0.75}]
        else
          []
        end

      # Main frame — hold for the step's pause duration
      svg = render_svg(meta, messages, max_height, cover_data)
      svg_path = Path.join(frames_dir, "frame_#{prefix}_b.svg")
      png_path = Path.rootname(svg_path) <> ".png"
      File.write!(svg_path, svg)
      svg_to_png(svg_path, png_path)

      frames ++ [{png_path, current_step.pause}]
    end)
  end

  defp svg_to_png(svg_path, png_path) do
    {_, 0} =
      System.cmd("resvg", [
        svg_path,
        png_path,
        "--width", "#{@width}"
      ], stderr_to_stdout: true)
  end

  # --- SVG Rendering ---

  defp render_svg(meta, messages, height, cover_data, opts \\ []) do
    show_typing = Keyword.get(opts, :typing, false)

    {bubble_elements, y_after_bubbles} = render_bubbles(messages, @header_height + 12, cover_data)

    {all_elements, content_bottom} =
      if show_typing do
        {typing_el, y_after_typing} = render_typing_indicator(y_after_bubbles + @bubble_gap, meta.context)
        {bubble_elements <> typing_el, y_after_typing + 20}
      else
        {bubble_elements, y_after_bubbles + 20}
      end

    scroll_offset = max(0, content_bottom - height)
    header = render_header(meta)

    # If content overflows, clip to area below header and scroll up
    scrollable_content =
      if scroll_offset > 0 do
        """
        <defs>
          <clipPath id="content-clip">
            <rect x="0" y="#{@header_height}" width="#{@width}" height="#{height - @header_height}"/>
          </clipPath>
        </defs>
        <g clip-path="url(#content-clip)">
          <g transform="translate(0, #{-scroll_offset})">
            #{all_elements}
          </g>
        </g>
        """
      else
        all_elements
      end

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{height}" viewBox="0 0 #{@width} #{height}">
      <defs>
        <style>
          @font-face { font-family: 'SF'; src: local('SF Pro Text'), local('SF Pro Display'), local('.SF NS Text'), local('Helvetica Neue'), local('Helvetica'), local('Arial'); }
        </style>
      </defs>
      <rect width="#{@width}" height="#{height}" fill="#{@bg}"/>
      #{scrollable_content}
      #{header}
    </svg>
    """
  end

  defp render_header(meta) do
    initials = meta.chat_name |> String.split(" ") |> Enum.map(&String.first/1) |> Enum.take(2) |> Enum.join()
    avatar_color = if meta.context == "dm", do: "#5b7fb5", else: "#4caf50"

    """
    <rect x="0" y="0" width="#{@width}" height="#{@header_height}" fill="#{@header_bg}"/>
    <line x1="0" y1="#{@header_height}" x2="#{@width}" y2="#{@header_height}" stroke="#{@header_border}" stroke-width="1"/>
    <circle cx="28" cy="#{div(@header_height, 2)}" r="16" fill="#{avatar_color}"/>
    <text x="28" y="#{div(@header_height, 2) + 5}" text-anchor="middle" font-family="SF, Helvetica, Arial, sans-serif" font-size="12" font-weight="600" fill="white">#{esc(initials)}</text>
    <text x="52" y="#{div(@header_height, 2) + 5}" font-family="SF, Helvetica, Arial, sans-serif" font-size="15" font-weight="600" fill="#{@text_color}">#{esc(meta.chat_name)}</text>
    """
  end

  defp render_bubbles(messages, start_y, cover_data) do
    messages
    |> Enum.reduce({"", start_y}, fn msg, {elements, y} ->
      {el, new_y} = render_message(msg, y, cover_data)
      {elements <> el, new_y}
    end)
  end

  defp render_message(msg, y, cover_data) do
    if msg.is_poll do
      render_poll_message(msg, y)
    else
      render_text_message(msg, y, cover_data)
    end
  end

  defp render_text_message(msg, y, cover_data) do
    is_user = msg.sender == "user"
    lines = wrap_text(msg.text, @bubble_max_width - @bubble_padding_x * 2)
    text_height = length(lines) * @line_height

    # Cover handling — height is based on spec, rendering uses downloaded data
    n_covers = length(msg.covers)
    has_covers = n_covers > 0
    cover_section_h = if has_covers, do: @cover_height + @bubble_gap, else: 0

    bubble_h = @bubble_padding_y + cover_section_h + text_height + @bubble_padding_y
    text_w = calc_bubble_width(lines) + @bubble_padding_x * 2

    cover_row_w =
      if has_covers do
        n_covers * @cover_width + max(n_covers - 1, 0) * @bubble_gap + @bubble_padding_x * 2
      else
        0
      end

    bubble_w = max(text_w, cover_row_w)

    # Name label (skip in DMs — only two participants)
    is_dm = msg.context == "dm"
    name_y = y

    {name_el, bubble_y} =
      if is_dm do
        {"", name_y}
      else
        el =
          if is_user do
            ~s(<text x="#{@width - 14}" y="#{name_y + 12}" text-anchor="end" font-family="SF, Helvetica, Arial, sans-serif" font-size="11" fill="#{@name_color}">#{esc(msg.name)}</text>)
          else
            ~s(<text x="14" y="#{name_y + 12}" font-family="SF, Helvetica, Arial, sans-serif" font-size="11" fill="#{@name_color}">#{esc(msg.name)}</text>)
          end

        {el, name_y + @name_height + 2}
      end

    {bubble_x, fill, _text_anchor, text_x} =
      if is_user do
        x = @width - 14 - bubble_w
        {x, @bubble_outgoing, "start", x + @bubble_padding_x}
      else
        {14, @bubble_incoming, "start", 14 + @bubble_padding_x}
      end

    bubble_el =
      ~s(<rect x="#{bubble_x}" y="#{bubble_y}" width="#{bubble_w}" height="#{bubble_h}" rx="16" fill="#{fill}"/>)

    # Render cover images inside the bubble
    cover_els =
      if has_covers do
        cover_y = bubble_y + @bubble_padding_y
        total_covers_w = n_covers * @cover_width + max(n_covers - 1, 0) * @bubble_gap
        start_x = bubble_x + div(bubble_w - total_covers_w, 2)

        msg.covers
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {isbn, i} ->
          case Map.get(cover_data, isbn) do
            nil ->
              ""

            data_uri ->
              cx = start_x + i * (@cover_width + @bubble_gap)
              clip_id = "cover-#{isbn}-#{trunc(y)}"

              ~s[<defs><clipPath id="#{clip_id}"><rect x="#{cx}" y="#{cover_y}" width="#{@cover_width}" height="#{@cover_height}" rx="6"/></clipPath></defs>] <>
                ~s[<image x="#{cx}" y="#{cover_y}" width="#{@cover_width}" height="#{@cover_height}" href="#{data_uri}" preserveAspectRatio="xMidYMid slice" clip-path="url(##{clip_id})"/>]
          end
        end)
      else
        ""
      end

    # Text lines — offset below covers if present
    text_base_y = bubble_y + @bubble_padding_y + cover_section_h

    text_els =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, i} ->
        ly = text_base_y + @line_height * i + 13
        ~s(<text x="#{text_x}" y="#{ly}" font-family="SF, Helvetica, Arial, sans-serif" font-size="13" fill="#{@text_color}">#{esc(line)}</text>)
      end)

    element = name_el <> "\n" <> bubble_el <> "\n" <> cover_els <> "\n" <> text_els <> "\n"
    new_y = bubble_y + bubble_h + @bubble_gap

    {element, new_y}
  end

  # --- Poll Rendering ---

  defp render_poll_message(msg, y) do
    # Parse question and options from poll text
    {question, options_text} =
      case String.split(msg.text, "\n\n", parts: 2) do
        [q, o] -> {q, o}
        [q] -> {q, ""}
      end

    options =
      options_text
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_poll_option/1)

    has_votes = Enum.any?(options, &(&1.votes != nil))
    total_votes = if has_votes, do: options |> Enum.map(&(&1.votes || 0)) |> Enum.sum(), else: 0

    # Dimensions
    question_lines = wrap_text(question, @bubble_max_width - @bubble_padding_x * 2)
    question_height = length(question_lines) * @line_height
    question_gap = 10
    options_height = length(options) * @option_height + max(length(options) - 1, 0) * @option_gap

    bubble_h = @bubble_padding_y + question_height + question_gap + options_height + @bubble_padding_y
    bubble_w = @bubble_max_width
    bubble_x = 14

    # Name label (skip in DMs)
    is_dm = msg.context == "dm"
    name_y = y

    {name_el, bubble_y} =
      if is_dm do
        {"", name_y}
      else
        el = ~s(<text x="14" y="#{name_y + 12}" font-family="SF, Helvetica, Arial, sans-serif" font-size="11" fill="#{@name_color}">#{esc(msg.name)}</text>)
        {el, name_y + @name_height + 2}
      end

    bubble_el =
      ~s(<rect x="#{bubble_x}" y="#{bubble_y}" width="#{bubble_w}" height="#{bubble_h}" rx="16" fill="#{@poll_bg}"/>)

    # Question text (bold)
    text_x = bubble_x + @bubble_padding_x

    question_els =
      question_lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, i} ->
        ly = bubble_y + @bubble_padding_y + @line_height * i + 13
        ~s(<text x="#{text_x}" y="#{ly}" font-family="SF, Helvetica, Arial, sans-serif" font-size="13" font-weight="600" fill="#{@text_color}">#{esc(line)}</text>)
      end)

    # Option pill buttons
    options_start_y = bubble_y + @bubble_padding_y + question_height + question_gap
    option_w = bubble_w - @bubble_padding_x * 2
    option_rx = div(@option_height, 2)

    option_els =
      options
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {opt, i} ->
        oy = options_start_y + i * (@option_height + @option_gap)
        ox = bubble_x + @bubble_padding_x

        if has_votes do
          render_voted_option(opt, ox, oy, option_w, option_rx, total_votes, i, y)
        else
          render_unvoted_option(opt, ox, oy, option_w, option_rx)
        end
      end)

    element = name_el <> "\n" <> bubble_el <> "\n" <> question_els <> "\n" <> option_els <> "\n"
    new_y = bubble_y + bubble_h + @bubble_gap

    {element, new_y}
  end

  defp render_voted_option(opt, ox, oy, option_w, option_rx, total_votes, index, parent_y) do
    bg_fill = if opt.selected, do: "#1a3d6e", else: "#2a2b2e"
    bar_fill = if opt.selected, do: "#2c6bed", else: "#3a3b3e"
    pct = if total_votes > 0, do: (opt.votes || 0) / total_votes, else: 0
    bar_w = max(trunc(option_w * pct), 0)
    clip_id = "opt-clip-#{index}-#{trunc(parent_y)}"

    bg = ~s(<rect x="#{ox}" y="#{oy}" width="#{option_w}" height="#{@option_height}" rx="#{option_rx}" fill="#{bg_fill}"/>)

    clip =
      ~s[<defs><clipPath id="#{clip_id}"><rect x="#{ox}" y="#{oy}" width="#{option_w}" height="#{@option_height}" rx="#{option_rx}"/></clipPath></defs>]

    bar = ~s[<rect x="#{ox}" y="#{oy}" width="#{bar_w}" height="#{@option_height}" fill="#{bar_fill}" clip-path="url(##{clip_id})"/>]

    # Radio circle
    ccx = ox + 18
    ccy = oy + div(@option_height, 2)

    circle =
      if opt.selected do
        ~s(<circle cx="#{ccx}" cy="#{ccy}" r="8" fill="white"/>) <>
          ~s(<circle cx="#{ccx}" cy="#{ccy}" r="3.5" fill="#2c6bed"/>)
      else
        ~s(<circle cx="#{ccx}" cy="#{ccy}" r="8" stroke="#666" stroke-width="1.5" fill="none"/>)
      end

    # Option text
    text_x = ox + 34
    text_y = oy + div(@option_height, 2) + 5
    text = ~s(<text x="#{text_x}" y="#{text_y}" font-family="SF, Helvetica, Arial, sans-serif" font-size="13" fill="#{@text_color}">#{esc(opt.name)}</text>)

    # Vote count (right-aligned)
    votes_label = if opt.votes == 1, do: "1 vote", else: "#{opt.votes || 0} votes"
    votes_x = ox + option_w - 14
    votes_el = ~s(<text x="#{votes_x}" y="#{text_y}" text-anchor="end" font-family="SF, Helvetica, Arial, sans-serif" font-size="11" fill="#{@name_color}">#{esc(votes_label)}</text>)

    Enum.join([bg, clip, bar, circle, text, votes_el], "\n")
  end

  defp render_unvoted_option(opt, ox, oy, option_w, option_rx) do
    bg = ~s(<rect x="#{ox}" y="#{oy}" width="#{option_w}" height="#{@option_height}" rx="#{option_rx}" fill="none" stroke="#4a4a4c" stroke-width="1.5"/>)
    text_x = ox + 16
    text_y = oy + div(@option_height, 2) + 5
    text = ~s(<text x="#{text_x}" y="#{text_y}" font-family="SF, Helvetica, Arial, sans-serif" font-size="13" fill="#{@text_color}">#{esc(opt.name)}</text>)

    bg <> "\n" <> text
  end

  defp parse_poll_option(text) do
    {selected, rest} =
      cond do
        String.starts_with?(text, "☑") ->
          {true, text |> String.slice(1..-1//1) |> String.trim_leading()}

        String.starts_with?(text, "☐") ->
          {false, text |> String.slice(1..-1//1) |> String.trim_leading()}

        true ->
          {false, text}
      end

    case String.split(rest, "\u2219") do
      [name, votes_text] ->
        votes =
          case Regex.run(~r/(\d+)/, String.trim(votes_text)) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        %{name: String.trim(name), selected: selected, votes: votes}

      _ ->
        %{name: String.trim(rest), selected: selected, votes: nil}
    end
  end

  # --- Typing Indicator ---

  defp render_typing_indicator(y, context \\ "group") do
    bubble_w = 60
    bubble_h = 32
    is_dm = context == "dm"

    {name_el, bubble_y} =
      if is_dm do
        {"", y}
      else
        el = ~s(<text x="14" y="#{y + 12}" font-family="SF, Helvetica, Arial, sans-serif" font-size="11" fill="#{@name_color}">Yonderbook Clubs</text>)
        {el, y + @name_height + 2}
      end

    bubble_el =
      ~s(<rect x="14" y="#{bubble_y}" width="#{bubble_w}" height="#{bubble_h}" rx="16" fill="#{@bubble_incoming}"/>)

    dots =
      [0, 1, 2]
      |> Enum.map_join("\n", fn i ->
        cx = 28 + i * 12
        cy = bubble_y + div(bubble_h, 2)
        ~s(<circle cx="#{cx}" cy="#{cy}" r="3.5" fill="#{@typing_dot}"/>)
      end)

    element = name_el <> "\n" <> bubble_el <> "\n" <> dots <> "\n"
    {element, bubble_y + bubble_h + @bubble_gap}
  end

  # --- Text Utilities ---

  defp wrap_text(text, max_width) do
    max_chars = trunc(max_width / @char_width)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if line == "" do
        [""]
      else
        wrap_line(line, max_chars)
      end
    end)
  end

  defp wrap_line(line, max_chars) do
    words = String.split(line, " ")

    words
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [] ->
          [word]

        [current | rest] ->
          candidate = current <> " " <> word

          if String.length(candidate) <= max_chars do
            [candidate | rest]
          else
            [word, current | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp calc_bubble_width(lines) do
    max_len = lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    min(trunc(max_len * @char_width) + 4, @bubble_max_width - @bubble_padding_x * 2)
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
