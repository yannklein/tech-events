puts 'Reset seeds'
TkyEvenEvent.destroy_all
TkyEvenMeetup.destroy_all
puts 'Seeds reset'

puts 'Creating Tokyo meetups'
jp_meetup_names = %w[
  tokyo-meetups
  tokyo-developer-meetup-group
  Machine-Learning-Tokyo
  Le-Wagon-Tokyo-Coding-Station
  tokyo-rails
  Women-Who-Code-Tokyo
  StartupTokyo
  Tokyo-Startup-Engineering
  devjapan
  tokyofintech
  tokyo-ai-movies-and-films
  robotics-x-tokyo
  tokyo-digital-nomads-community
]

jp_dk_names = %w[trbmeetup uxtalktokyo rubyassociation]

jp_meetup_names.each do |name|
  TkyEvenMeetup.create(name:, platform: 'meetup', city: 'tokyo')
  puts "Meetup group named #{name} created"
end
puts 'Meetups groups created'

jp_dk_names.each do |name|
  TkyEvenMeetup.create(name:, platform: 'doorkeeper', city: 'tokyo')
  puts "Doorkeeper group named #{name} created"
end
puts 'Doorkeeper groups created'

puts 'Creating Barcelona meetups'
bcn_meetup_names = %w[
  barcelona-amazon-web-services-meetup
  le-wagon-barcelona
  tech-barcelona
  codebar-barcelona
  barcelona-machine-learning-meetups
  barcelonajs
  python-barcelona
  meetup-group-nkodwxya
  notjustdev
  immigration-lawyers-abogados-de-extranajeria
  ai-engineers-barcelona
]

bcn_meetup_names.each do |name|
  TkyEvenMeetup.create(name:, platform: 'meetup', city: 'barcelona')
  puts "Meetup group named #{name} created"
end

puts 'Creating Barcelona meetups'
luma_meetup_names = %w[
  openfortHQ
]

tky_luma_meetup_names = %w[
  frenchtechtokyo
]

luma_meetup_names.each do |name|
  TkyEvenMeetup.create(name:, platform: 'luma', city: 'barcelona')
  puts "Meetup group named #{name} created (bcn)"
end

tky_luma_meetup_names.each do |name|
  TkyEvenMeetup.create(name:, platform: 'luma', city: 'tokyo')
  puts "Meetup group named #{name} created (tky)"
end

puts 'Meetups groups created'
