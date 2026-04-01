class ApiFetcher
  def initialize(platform_name)
    @platform_name = platform_name
    @groups = TkyEvenMeetup.where(platform: @platform_name) || []
    @events = []
  end

  def fetch_events(&specific_api_fetch)
    puts "[#{@platform_name.upcase}: Events fetching for #{@groups.size} groups 📆]"
    @groups.each do |group|
      sleep 1
      puts "  Fetching events for: #{group.name}"
      @events += specific_api_fetch.call(group)
    end
    puts "[#{@platform_name.upcase}: #{@events.size} events fetched (some may already be stored) ✅]"
    self
  rescue StandardError => e
    puts "  ⚠️ Fetching events for the groups didn't work: #{e.class}: #{e.message}"
    self
  end

  def store_events
    puts "[#{@platform_name.upcase}: Events storing　💾]"
    event_created = 0
    @events.each do |event|
      next unless TkyEvenEvent.where(meetup_event_id: event[:meetup_event_id]).empty?

      puts "  Store event: #{event[:name]}"
      event_created += 1
      TkyEvenEvent.create(event)
    end
    puts "[#{@platform_name.upcase}: #{event_created} events stored in DB ✅]"
    puts ''
  end
end
