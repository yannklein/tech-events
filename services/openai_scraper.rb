require "ruby/openai"
require 'json'

class OpenaiScraper
  def initialize(platform_name, base_url)
    @platform_name = platform_name
    @base_url = base_url
    @groups = Group.where(platform: @platform_name) || []
    @events = []
    @client = OpenAI::Client.new(
      access_token: ENV['OPENAI_API_KEY'],
      request_timeout: 300 # 5 minutes for large payloads
    )
  end

  def fetch_events
    puts "[#{@platform_name.upcase}: Events AI scraping for #{@groups.size} groups 🧠]"
    @groups.each do |group|
      sleep 1
      puts "  Scraping events for: #{group.name}"
      # p group.name, @base_url
      raw_html = get_raw_html(group.name, @base_url)
      # p raw_html[0..1000]
      @events += openai_scrape(group, raw_html)
    end
    puts "[#{@platform_name.upcase}: #{@events.size} events scraped (some may already be stored) ✅]"
    self
  rescue StandardError => e
    puts "  ⚠️ Scraping events for the groups didn't work: #{e.class}: #{e.message}"
    self
  end

  def openai_scrape(group, raw_html)
    # truncated_html = truncate_html(raw_html)
    @instructions = <<~INSTRUCTIONS
      Below is the raw HTML of the page of the #{group.name} group on the #{@platform_name} event platform. Look for all the future events of the group.
      Your output should be a JSON array of objects, each representing an event. 
      If you don't find any event, your output should be a JSON empty array.
      Your output should only contain the JSON array mentioned, nothing else.
      Your response MUST NOT contain markdown code blocks (like ```json) — just the raw JSON array.
      Each object should contain the following fields:
      - meetup_event_id: The unique identifier for the event on the #{@platform_name} platform (composed of letters and numbers only)
      - name: The name of the event
      - venue: The venue of the event (if available), if not the value should be 'Remote or no venue info'
      - event_date: The start time of the event in ISO 8601 format
      - start_time: The local start time of the event in format HH:MM
      - url: The URL of the event on the #{@platform_name} platform
      - description: The description of the event

      [The raw HTML]

      #{raw_html}
    INSTRUCTIONS

    if @instructions.length > 100_000
      puts "    ⚠️ Instruction length too long (#{@instructions.length}). Skipping group: #{group.name}"
      return []
    end

    puts "    ℹ️ Instruction length: #{@instructions.length}"
    response = @client.chat(
      parameters: {
        model: 'gpt-4o-mini',
        messages: [
          { role: 'user', content: @instructions }
        ]
      }
    )
    raw_events_json = response.dig('choices', 0, 'message', 'content')
    raw_events = JSON.parse(raw_events_json)
    raw_events.map do |raw_event|
      {
        meetup_event_id: raw_event['meetup_event_id'],
        group: group,
        name: "@#{raw_event['start_time']} | #{raw_event['name']}",
        venue: raw_event['venue'],
        event_date: raw_event['event_date'],
        url: raw_event['url'],
        description: "<p><a href='#{raw_event['url']}'>Open the event page</a></p>#{raw_event['description']}" || ''
      }
    end
  rescue JSON::ParserError => e
    puts "    ⚠️ Failed to parse JSON response for group: #{group.name}. Error: #{e.message}"
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

# OpenaiScraper
#   .new('meetup', 'https://www.meetup.com/')
#   .fetch_events
#   .store_events
