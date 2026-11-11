namespace :tillbell do
  desc "Check the Tillbell configuration. ONLINE=1 also asks Google; PLANS=premium:monthly,premium:yearly checks those plans exist."
  task check: :environment do
    icons = { ok: "OK  ", warn: "WARN", fail: "FAIL" }
    online = !%w[0 false no].include?(ENV["ONLINE"].to_s.strip.downcase) && ENV["ONLINE"].present?
    plans = ENV["PLANS"].to_s.split(",").map(&:strip).reject(&:empty?)
    check = Tillbell::Check.new(online: online, plans: plans.presence || Tillbell.plans)

    check.call.each do |result|
      puts "#{icons.fetch(result.status)} #{result.label}#{": #{result.detail}" if result.detail}"
    end
    puts "\nGoogle was not asked: run again with ONLINE=1 to check the key, its rights and your subscriptions." unless online

    abort "\nSomething will not work: see the README, \"Google Play setup\"." unless check.ok?
    puts "\nEverything is in place."
  end
end
