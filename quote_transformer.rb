# frozen_string_literal: true

require 'csv'
require 'net/http'

def download_quote(name)
  printf "Downloading #{name}..."
  contents = Net::HTTP.get(URI("https://www.coingecko.com/price_charts/export/#{name}/usd.csv"))
  CSV.open("./quotes/#{name}.csv", "w") do |csv|
    csv << %w[Date Open Close High Low Volume] # Add headers
    CSV.parse(contents, headers: true).each do |line|
      csv << [
        line['snapped_at'][0..9],
        line['price'],
        line['price'],
        0,
        0,
        line['total_volume'] || 0,
      ]
    end
  end
  puts "done."
end

# Majors
download_quote('bitcoin')
download_quote('ethereum')
download_quote('cardano')

# Other Current Holdings
# download_quote('terra')
# download_quote('terra-luna-classic')
# download_quote('tether')

# Historical
# download_quote('audius')
# download_quote('basic-attention-token')
# download_quote('binancecoin')
# download_quote('chainlink')
# download_quote('dogecoin')
# download_quote('ergo')
# download_quote('fetch-ai')
# download_quote('flux')
# download_quote('harmony')
# download_quote('livepeer')
# download_quote('usdm')
# download_quote('polkadot')
# download_quote('polygon')
# download_quote('ravencoin')
# download_quote('ripple')
# download_quote('shiba-inu')
# download_quote('stellar')
# download_quote('the-graph')
# download_quote('usdc')
# download_quote('vechain')
# download_quote('vethor-token')
# download_quote('zcash')
