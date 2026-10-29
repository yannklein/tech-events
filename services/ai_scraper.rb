require 'ruby_llm'
require 'json'

class AiScraper
  # Claude Haiku 5.5 is not in ruby_llm's model registry yet, hence assume_model_exists below.
  MODEL = ENV.fetch('ANTHROPIC_MODEL', 'claude-haiku-5-5')
  MAX_INPUT_LENGTH = 100_000

  EVENTS_SCHEMA = {
    type: 'object',
    properties: {
      events: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            meetup_event_id: { type: 'string', description: 'Unique identifier of the event on the platform (letters and numbers only)' },
            name: { type: 'string', description: 'Name of the event' },
            venue: { type: 'string', description: "Venue of the event, or 'Remote or no venue info' if unavailable" },
            event_date: { type: 'string', description: 'Start time of the event in ISO 8601 format' },
            start_time: { type: 'string', description: 'Local start time of the event in format HH:MM' },
            url: { type: 'string', description: 'URL of the event on the platform' },
            description: { type: 'string', description: 'Description of the event' }
          },
          required: %w[meetup_event_id name venue event_date start_time url description],
          additionalProperties: false
        }
      }
    },
    required: ['events'],
    additionalProperties: false
  }.freeze

  def initialize(platform_name, base_url)
    @platform_name = platform_name
    @base_url = base_url
    @groups = Group.where(platform: @platform_name) || []
    @events = []
  end

  def fetch_events
    puts "[#{@platform_name.upcase}: Events AI scraping for #{@groups.size} groups 🧠]"
    @groups.each do |group|
      sleep 1
      puts "  Scraping events for: #{group.name}"
      raw_html = get_raw_html(group.name, @base_url)
      @events += llm_scrape(group, raw_html)
    end
    puts "[#{@platform_name.upcase}: #{@events.size} events scraped (some may already be stored) ✅]"
    self
  rescue StandardError => e
    puts "  ⚠️ Scraping events for the groups didn't work: #{e.class}: #{e.message}"
    self
  end

  def llm_scrape(group, raw_html)
    if raw_html.strip.empty?
      puts "    ℹ️ No event data found on the page. Skipping LLM call for group: #{group.name}"
      return []
    end

    if raw_html.length > MAX_INPUT_LENGTH
      puts "    ⚠️ Page data too long (#{raw_html.length}). Skipping group: #{group.name}"
      return []
    end

    puts "    ℹ️ Page data length: #{raw_html.length}"
    response = new_chat.ask(<<~PROMPT)
      Today is #{Date.today.iso8601}. Below is the page data of the #{group.name} group on the #{@platform_name} event platform.

      <page_data>
      #{raw_html}
      </page_data>
    PROMPT
    puts "    ℹ️ Tokens: #{response.tokens.input} in / #{response.tokens.output} out"

    response.parsed.fetch('events', []).map do |raw_event|
      {
        meetup_event_id: raw_event['meetup_event_id'],
        group: group,
        name: "@#{raw_event['start_time']} | #{raw_event['name']}",
        venue: raw_event['venue'],
        event_date: raw_event['event_date'],
        url: raw_event['url'],
        description: "<p><a href='#{raw_event['url']}'>Open the event page</a></p>#{raw_event['description']}"
      }
    end
  rescue JSON::ParserError => e
    puts "    ⚠️ Failed to parse JSON response for group: #{group.name}. Error: #{e.message}"
    []
  rescue RubyLLM::Error => e
    puts "    ⚠️ LLM call failed for group: #{group.name}. #{e.class}: #{e.message}"
    []
  end

  def store_events
    puts "[#{@platform_name.upcase}: Events storing　💾]"
    event_created = 0
    @events.each do |event|
      puts "  Try to store event: #{event[:name]}, id: #{event[:meetup_event_id]}"
      next unless Event.where(meetup_event_id: event[:meetup_event_id]).empty?

      puts "  Store event: #{event[:name]}"
      event_created += 1
      Event.create(event)
    end
    puts "[#{@platform_name.upcase}: #{event_created} events stored in DB ✅]"
    puts ''
  end

  private

  def new_chat
    RubyLLM.chat(model: MODEL, provider: :anthropic, assume_model_exists: true)
           .with_instructions(<<~INSTRUCTIONS)
             You extract events from the page data of a group on the #{@platform_name} event platform.
             Return all the future events of the group. If you don't find any, return an empty events array.
             For each event:
             - meetup_event_id: the unique identifier of the event on the #{@platform_name} platform (letters and numbers only)
             - venue: the venue of the event, or 'Remote or no venue info' if not available
             - event_date: the start time of the event in ISO 8601 format
             - start_time: the local start time of the event in format HH:MM
             - url: the URL of the event on the #{@platform_name} platform
           INSTRUCTIONS
           .with_schema(EVENTS_SCHEMA)
           .with_thinking(effort: :low)
           .with_max_output_tokens(16_000)
  end

  def slim_json(data, keep_keys: %w[name title date time url venue description id eventUrl])
    case data
    when Hash
      data.each_with_object({}) do |(k, v), h|
        h[k] = slim_json(v, keep_keys: keep_keys) if keep_keys.any? { |key| k.to_s.downcase.include?(key.downcase) } || v.is_a?(Hash) || v.is_a?(Array)
      end
    when Array
      data.map { |item| slim_json(item, keep_keys: keep_keys) }
    else
      data
    end
  end

  def clean_html(html)
    # Remove scripts, styles, comments, and whitespace
    html.gsub(/<script[^>]*>.*?<\/script>/mi, '')
        .gsub(/<style[^>]*>.*?<\/style>/mi, '')
        .gsub(/<!--.*?-->/m, '')
        .gsub(/\s+/, ' ')
        .strip
  end

  def process_in_chunks(content, chunk_size: 30_000)
    return [content] if content.length <= chunk_size
    content.scan(/.{1,#{chunk_size}}/m)
  end

  def get_raw_html(group_name, base_url)
    # Construct the full Luma page URL
    url = "#{base_url}#{group_name}"

    url += '/events/' if @platform_name == 'meetup'

    browser = Watir::Browser.new(:chrome, headless: true, options: {
      args: [
        '--no-sandbox',
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--disable-extensions',
        '--disable-infobars',
        '--disable-browser-side-navigation',
        '--disable-features=VizDisplayCompositor',
        '--window-size=1280,800'
      ]
    })
    browser.goto(url)

    # Wait for the page to fully load — adjust wait time or use a smarter wait if needed
    browser.wait_until(timeout: 10) { |b| b.ready_state == "complete" }

    raw_html = browser.html.force_encoding("UTF-8")

    if @platform_name == 'luma'
      extracted = raw_html.scan(/<script[^>]*type="application\/ld\+json"[^>]*>(.*?)<\/script>/m).flatten.join
      raw_html = extracted || raw_html
    elsif @platform_name == 'eventbrite'
      match = raw_html.match(/window\.__SERVER_DATA__\s*=\s*(\{.*?\});/m)
      if match
        data = JSON.parse(match[1])
        raw_html = slim_json(data).to_json
      else
        raw_html = ""
      end
    elsif @platform_name == 'meetup'
      match = raw_html.match(/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/m)
      if match
        data = JSON.parse(match[1])
        # Extract only the events data from the nested structure
        events_data = data.dig('props', 'pageProps', 'events') ||
                      data.dig('props', 'pageProps', '__APOLLO_STATE__')
        # Slim down the JSON to keep only event-relevant fields
        raw_html = slim_json(events_data).to_json
      else
        raw_html = ""
      end
    else
      # For unknown platforms, clean the HTML
      raw_html = clean_html(raw_html)
    end
    raw_html

  rescue StandardError => e
    puts "Error fetching page with Watir: #{e.class} - #{e.message}"
    browser&.close
    ""
  ensure
    browser&.close
  end

  def truncate_html(raw_html, max_length = 5000)
    return raw_html if raw_html.length <= max_length

    # Extract meaningful parts of the HTML (e.g., <script>, <div>, <meta>)
    important_parts = raw_html.scan(/<script.*?>.*?<\/script>|<div.*?>.*?<\/div>|<meta.*?>/m).join("\n")
    truncated = important_parts[0...max_length]
    truncated += "\n<!-- Truncated due to length -->" if important_parts.length > max_length
    truncated
  end
end

# AiScraper
#   .new('meetup', 'https://www.meetup.com/')
#   .fetch_events
#   .store_events
