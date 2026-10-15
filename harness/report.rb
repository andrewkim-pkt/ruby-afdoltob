#!/usr/bin/env ruby
# Aggregate a mirrored Ruby FDO campaign into a report. Runs ON the DUT (any ruby will do).
#
#   ./report.rb /home/ubuntu/ruby-fdo/res/campaign-YYYYmmdd-HHMMSS
#
# Input is one json per (direction, benchmark) as written by ruby-campaign.sh:
#   { "metadata": {arm => ruby -v}, "raw_data": {arm => {bench => {"warmup"=>[], "bench"=>[secs]}}} }
#
# HOW THE MIRRORED NUMBER IS FORMED, and what is deliberately NOT hidden.
# Each benchmark is measured twice: once with the arms in forward order, once reversed. The two
# passes are reported SEPARATELY as well as combined, because their disagreement is the honest
# error bar. Averaging a +4% and a -3% into "+0.5%" would present an unattributable result as a
# finding -- on the PG 18 NUMA work an arm ordering reversed outright between two runs of the same
# binaries, and the lesson was that the disagreement is the result.
#
# Per-benchmark speedup is base_time / arm_time, so >1.0 means the arm is FASTER. Aggregation
# across benchmarks is the GEOMETRIC mean, which is the only correct average for ratios -- an
# arithmetic mean of speedups would let one big win on a slow benchmark dominate.

require 'json'

dir = ARGV[0] or abort "usage: report.rb <campaign-dir>"
manifest = File.join(dir, 'MANIFEST')
md5 = {}
if File.exist?(manifest)
  File.readlines(manifest).each do |l|
    md5[$1] = $2 if l =~ /^\s+(\S+) md5=(\h+)/
  end
end

# data[dir][bench][arm] = [seconds, ...]
data = { 'fwd' => {}, 'rev' => {} }
Dir[File.join(dir, '*.json')].sort.each do |f|
  base = File.basename(f, '.json')
  d = base.include?('-fwd-') ? 'fwd' : (base.include?('-rev-') ? 'rev' : nil)
  next unless d
  j = JSON.parse(File.read(f)) rescue next
  (j['raw_data'] || {}).each do |arm, benches|
    benches.each do |bench, rec|
      times = rec['bench']
      next unless times.is_a?(Array) && !times.empty?
      (data[d][bench] ||= {})[arm] = times
    end
  end
end

benches = (data['fwd'].keys | data['rev'].keys).sort
abort "no data found in #{dir}" if benches.empty?

# Arm order as listed in the manifest, falling back to discovery.
arms = md5.keys
arms = data['fwd'].values.flat_map(&:keys).uniq if arms.empty?
arms = arms.select { |a| benches.any? { |b| data['fwd'].dig(b, a) || data['rev'].dig(b, a) } }
base_arm = arms.include?('base') ? 'base' : arms.first

def mean(a) = a.sum / a.size.to_f
def stdev(a)
  return 0.0 if a.size < 2
  m = mean(a); Math.sqrt(a.sum { |x| (x - m)**2 } / (a.size - 1).to_f)
end
def geomean(a)
  a = a.compact.reject { |x| x <= 0 }
  return nil if a.empty?
  Math.exp(a.sum { |x| Math.log(x) } / a.size.to_f)
end

# ---- per-benchmark, per-direction speedups -------------------------------------------------
# sp[dir][arm] = [speedup per benchmark]
sp = { 'fwd' => Hash.new { |h, k| h[k] = [] }, 'rev' => Hash.new { |h, k| h[k] = [] } }
detail = {}   # detail[bench][arm] = {fwd:, rev:, mir:}

benches.each do |b|
  detail[b] = {}
  %w[fwd rev].each do |d|
    bt = data[d].dig(b, base_arm)
    next unless bt
    bm = mean(bt)
    arms.each do |a|
      at = data[d].dig(b, a)
      next unless at
      s = bm / mean(at)
      sp[d][a] << s
      (detail[b][a] ||= {})[d] = s
    end
  end
  detail[b].each_value { |h| h[:mir] = geomean([h['fwd'], h['rev']].compact) }
end

puts "=" * 100
puts "Ruby FDO mirrored report — #{File.basename(dir)}"
puts "=" * 100
if File.exist?(manifest)
  File.readlines(manifest).each { |l| puts "  #{l.rstrip}" unless l =~ /^\s+\S+ md5=/ }
end
puts "  benchmarks: #{benches.size}  (#{benches.join(', ')})"
puts

# ---- headline table -------------------------------------------------------------------------
puts "-" * 100
printf "%-10s %10s %10s %12s %10s  %s\n",
       'arm', 'fwd', 'rev', 'MIRRORED', 'spread', 'verdict'
puts "-" * 100
rows = []
arms.each do |a|
  f = geomean(sp['fwd'][a])
  r = geomean(sp['rev'][a])
  m = geomean([f, r].compact)
  next unless m
  # Spread between the two passes is the honest uncertainty on the mirrored figure.
  spread = (f && r) ? (f - r).abs * 100 : nil
  rows << [a, f, r, m, spread]
end
rows.each do |a, f, r, m, spread|
  pct = ->(x) { x ? format('%+.2f%%', (x - 1) * 100) : '--' }
  verdict =
    if a == base_arm then 'baseline'
    elsif f && r && ((f - 1) * (r - 1) < 0) then 'INSIDE NOISE (passes disagree in sign)'
    elsif spread && ((m - 1).abs * 100) < spread then 'inside noise (spread > effect)'
    elsif (m - 1).abs * 100 < 1.0 then 'inside noise (<1%)'
    else format('%s %.2f%%', (m > 1 ? 'faster by' : 'SLOWER by'), (m - 1).abs * 100)
    end
  printf "%-10s %10s %10s %12s %9s  %s\n",
         a, pct.(f), pct.(r), pct.(m), spread ? format('%.2f%%', spread) : '--', verdict
end
puts "-" * 100

# The customer's benchmark of record gets its own table rather than being one row of sixteen.
focus = ENV['FOCUS_BENCH'] || 'lobsters'
if detail.key?(focus)
  puts
  puts "=" * 100
  puts "FOCUS BENCHMARK: #{focus}  (reported separately at akim's request)"
  puts "=" * 100
  printf "%-10s %10s %10s %12s %10s\n", 'arm', 'fwd', 'rev', 'MIRRORED', 'ms'
  puts "-" * 60
  arms.each do |a|
    h = detail[focus][a] or next
    t = %w[fwd rev].map { |d| data[d].dig(focus, a) }.compact.map { |x| mean(x) }
    pct = ->(x) { x ? format('%+.2f%%', (x - 1) * 100) : '--' }
    printf "%-10s %10s %10s %12s %10s\n", a,
           pct.(h['fwd']), pct.(h['rev']), pct.(h[:mir]),
           t.empty? ? '--' : format('%.1f', mean(t) * 1000)
  end
  puts "-" * 60
end

puts
puts "Speedup vs #{base_arm}; geometric mean across benchmarks. + = faster."
puts "MIRRORED = geomean of the forward and reverse passes. 'spread' = |fwd - rev|, the"
puts "disagreement between the two orderings and the practical uncertainty on each figure."
puts

# ---- per-benchmark detail -------------------------------------------------------------------
puts "=" * 100
puts "Per-benchmark mirrored speedup vs #{base_arm} (%)"
puts "=" * 100
w = arms.reject { |a| a == base_arm }
printf "%-16s", 'bench'
w.each { |a| printf "%9s", a }
puts
puts "-" * (16 + 9 * w.size)
benches.each do |b|
  printf "%-16s", b
  w.each do |a|
    v = detail[b].dig(a, :mir)
    printf "%9s", v ? format('%+.1f', (v - 1) * 100) : '--'
  end
  puts
end
puts "-" * (16 + 9 * w.size)
printf "%-16s", 'GEOMEAN'
w.each do |a|
  m = geomean([geomean(sp['fwd'][a]), geomean(sp['rev'][a])].compact)
  printf "%9s", m ? format('%+.1f', (m - 1) * 100) : '--'
end
puts
puts

# ---- absolute times -------------------------------------------------------------------------
puts "=" * 100
puts "Absolute mean times, ms (mirrored: mean of both passes)"
puts "=" * 100
printf "%-16s", 'bench'
arms.each { |a| printf "%10s", a }
puts
puts "-" * (16 + 10 * arms.size)
benches.each do |b|
  printf "%-16s", b
  arms.each do |a|
    t = %w[fwd rev].map { |d| data[d].dig(b, a) }.compact.map { |x| mean(x) }
    printf "%10s", t.empty? ? '--' : format('%.1f', mean(t) * 1000)
  end
  puts
end
puts

puts "binaries:"
md5.each { |a, h| puts "  #{a.ljust(10)} #{h}" }
