# frozen_string_literal: true

require "date"
require "json"
require "active_support/core_ext/string/indent"
require "active_support/core_ext/object/blank"

# development
require "byebug"

class KoinlyTransformer
  attr_accessor :rendered_transactions
  attr_accessor :securities
  attr_accessor :transactions
  attr_accessor :currency_to_transactions_map
  attr_accessor :transaction_filter
  attr_accessor :id_to_cost_basis
  attr_accessor :position_id_map

  def initialize
    super
    self.rendered_transactions = []
    self.securities = {}
    self.transactions = []
    self.currency_to_transactions_map = {}
    self.id_to_cost_basis = {}
  end
  
  def add_transactions(transactions)
    self.transactions += transactions
    self
  end
  
  def set_filter(&filter)
    self.transaction_filter = filter
    self
  end
  
  def set_position_id_map(map)
    self.position_id_map = map
    position_id_map.transform_keys!(&:to_sym)
    self
  end
  
  def render
    process_transactions
    
    File.write('output.qfx', render_qfx)
    File.write('output.sql', render_sql)
  end
  
  private
  
  def format_short_id(id)
    id.nil? ? nil : id[0...7]
  end
  
  def format_security_symbol(symbol)
    "CRYPTO-#{symbol}"
  end

  def format_security_name(name)
    "#{name} (Manual)"
  end
  
  def register_transaction_currency(transaction_id, currency_symbol)
    currency_to_transactions_map[currency_symbol] ||= []
    currency_to_transactions_map[currency_symbol] << transaction_id
  end
  
  def process_buy_or_sell(transaction, action:)
    action = action.to_sym
    raise "`action` must be `buy` or `sell`" unless %i[buy sell].include?(action)
    ofx_action_name = action == :buy ? "BUY" : "SELL"
    action_human = action == :buy ? 'Buy' : 'Sell'
    element_1 = action == :buy ? 'to' : 'from'
    element_2 = action == :buy ? 'from' : 'to'
    to_amount = transaction.dig(element_1, 'amount')
    from_amount = transaction.dig(element_2, 'amount')
    total_direction = action == :buy ? '-' : ''
    fee_present = transaction['fee'].present?
    fee_fitid = "#{transaction['id']}-FEE"
    fee_currency_type = transaction.dig('fee', 'currency', 'type')
    commission_element = ""
    if fee_present && fee_currency_type == 'fiat'
      commission_element = "\n" + "<COMMISSION>#{transaction['fee']['amount']}<COMMISSION>".indent(4)
    end
    
    # Buy transaction
    self.rendered_transactions << <<~EOF
      <#{ofx_action_name}STOCK>
        <INV#{ofx_action_name}>
          <INVTRAN>
            <FITID>#{transaction['id']}</FITID>
            <DTTRADE>#{DateTime.parse(transaction['date']).strftime('%Y%m%d%H%M%S')}</DTTRADE>
            <MEMO>#{format_short_id(transaction['id'])} - #{action_human} #{transaction.dig(element_1, 'currency', 'symbol')} - via #{transaction.dig(element_1, 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})</MEMO>
          </INVTRAN>
          <SECID>
            <UNIQUEID>#{format_security_symbol(transaction.dig(element_1, 'currency', 'symbol'))}</UNIQUEID>
            <UNIQUEIDTYPE>OTHER</UNIQUEIDTYPE>
          </SECID>
          <UNITS>#{to_amount}</UNITS>
          <UNITPRICE>#{from_amount.to_f/to_amount.to_f}</UNITPRICE>
          <TOTAL>#{total_direction}#{from_amount}</TOTAL>
          <SUBACCTSEC>CASH</SUBACCTSEC>
          <SUBACCTFUND>CASH</SUBACCTFUND>#{commission_element}
        </INV#{ofx_action_name}>
      </#{ofx_action_name}STOCK>
    EOF
    register_transaction_currency(transaction['id'], transaction.dig(element_1, 'currency', 'symbol'))
    
    # Fee transaction
    if fee_present
      if fee_currency_type == 'crypto'
        process_add_or_remove_shares(
          id: fee_fitid,
          date: transaction['date'],
          memo: "#{action_human} #{transaction.dig(element_1, 'currency', 'symbol')} Fee - via #{transaction.dig(element_1, 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})",
          symbol: transaction['fee']['currency']['symbol'],
          units: transaction['fee']['amount'],
          action: :remove,
        )
      elsif fee_currency_type == 'fiat'
        # Already handled by commission, skipping...
      else
        raise "Fee type `#{fee_currency_type} for transaction #{transaction['id']} not supported"
      end
    end
  end

  def process_add_or_remove_shares(id:, date:, memo:, symbol:, units:, action:)
    action = action.to_sym
    raise 'Action must be `add` or `remove`' unless %i[add remove].include?(action)
    self.rendered_transactions << <<~EOF
      <TRANSFER>
        <INVTRAN>
          <FITID>#{id}</FITID>
          <DTTRADE>#{DateTime.parse(date).strftime('%Y%m%d%H%M%S')}</DTTRADE>
          <MEMO>#{format_short_id(id)} - #{memo}</MEMO>
        </INVTRAN>
        <SECID>
          <UNIQUEID>#{format_security_symbol(symbol)}</UNIQUEID>
          <UNIQUEIDTYPE>OTHER</UNIQUEIDTYPE>
        </SECID>
        <SUBACCTSEC>CASH</SUBACCTSEC>
        <UNITS>#{units}</UNITS>
        <TFERACTION>#{action == :add ? 'IN' : 'OUT'}</TFERACTION>
        <POSTYPE>LONG</POSTYPE>
      </TRANSFER>
    EOF
    register_transaction_currency(id, symbol)
  end
  
  def process_crypto_deposit_or_withdrawal(transaction, action:)
    action = action.to_sym
    raise 'Action must be `add` or `remove`' unless %i[deposit withdrawal].include?(action)
    
    # Throw an error if we find a to or fee for a deposit
    raise "Unexpected fee or from element for #{action} for `#{transaction['id']}`" if action == :deposit && transaction.dig('from').present? || transaction.dig('fee').present?
    raise "Unexpected fee or to element for #{action} for `#{transaction['id']}`" if action == :withdrawal && transaction.dig('to').present? || transaction.dig('fee').present?
    
    primary_element = action == :deposit ? 'to' : 'from'
    add_or_remove = action == :deposit ? :add : :remove
    
    process_add_or_remove_shares(
      id: transaction['id'],
      date: transaction['date'],
      memo: "#{action.capitalize} #{transaction[primary_element]['currency']['symbol']} - via #{transaction.dig(primary_element, 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})",
      symbol: transaction[primary_element]['currency']['symbol'],
      units: transaction[primary_element]['amount'],
      action: add_or_remove,
    )
  end
  
  def process_transfer_or_exchange(transaction, action:)
    action = action.to_sym
    raise 'Action must be `transfer` or `exchange`' unless %i[transfer exchange].include?(action)
    
    fee_type = transaction.dig('fee', 'currency', 'type')
  
    process_add_or_remove_shares(
      id: "#{transaction['id']}-#{action.upcase}-REMOVE",
      date: transaction['date'],
      memo: "#{action.capitalize} (source) #{transaction['from']['currency']['symbol']} - from #{transaction.dig('from', 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})",
      symbol: transaction['from']['currency']['symbol'],
      units: transaction['from']['amount'],
      action: :remove,
    )

    process_add_or_remove_shares(
      id: "#{transaction['id']}-#{action.upcase}-ADD",
      date: transaction['date'],
      memo: "#{action.capitalize} (destination) #{transaction['to']['currency']['symbol']} - to #{transaction.dig('to', 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})",
      symbol: transaction['to']['currency']['symbol'],
      units: transaction['to']['amount'],
      action: :add,
    )
    
    if fee_type == 'crypto'
      process_add_or_remove_shares(
        id: "#{transaction['id']}-#{action.upcase}-FEE",
        date: transaction['date'],
        memo: "#{action.capitalize} Fee #{transaction['fee']['currency']['symbol']} - from #{transaction.dig('fee', 'wallet', 'name') || 'Unknown'} (tx:#{transaction['txhash']})",
        symbol: transaction['fee']['currency']['symbol'],
        units: transaction['fee']['amount'],
        action: :remove,
      )
    elsif fee_type.present?
      raise "Unsupported fee type `#{fee_type}` for `#{transaction['id']}`"
    end
  end
  
  def process_transactions
    (transaction_filter.present? ? transactions.select(&transaction_filter) : transactions).each do |transaction|
      process_security(transaction.dig('from', 'currency'))
      process_security(transaction.dig('to', 'currency'))
      process_security(transaction.dig('fee', 'currency'))
      type = transaction['type'].to_sym
      case type
        when :buy; process_buy_or_sell(transaction, action: :buy)
        when :sell; process_buy_or_sell(transaction, action: :sell)
        when :crypto_deposit; process_crypto_deposit_or_withdrawal(transaction, action: :deposit)
        when :crypto_withdrawal; process_crypto_deposit_or_withdrawal(transaction, action: :withdrawal)
        when :transfer; process_transfer_or_exchange(transaction, action: :transfer)
        when :exchange; process_transfer_or_exchange(transaction, action: :exchange)
        # TODO: Assuming that these are already in the account since they're linked to the bank account...
        #   ...but we should probably print the amounts or something so we can at least match/verify
        when :fiat_deposit; next
        when :fiat_withdrawal; next
      else
        raise "Transaction `#{type}` not supported"
      end
    end
  end
  
  def process_security(element)
    return if element.nil?
    return unless element['type'] == 'crypto'
    symbol = element['symbol']
    return if securities[symbol].present?
    securities[symbol] = element['name']
    currency_to_transactions_map[symbol] ||= []
  end
  
  def render_qfx
    <<~EOF
      OFXHEADER:100
      DATA:OFXSGML
      VERSION:102
      SECURITY:NONE
      ENCODING:USASCII
      CHARSET:1252
      COMPRESSION:NONE
      OLDFILEUID:NONE
      NEWFILEUID:NONE
      
      <OFX>
        <SIGNONMSGSRSV1>
          <SONRS>
            <STATUS>
              <CODE>0
              <SEVERITY>INFO
            </STATUS>
            <DTSERVER>#{Time.now.utc.strftime('%Y%m%d%H%M%S')}[0:GMT]
            <LANGUAGE>ENG
            <FI>
              <ORG>Vanguard
              <FID>15103
            </FI>
            <INTU.BID>15103
          </SONRS>
        </SIGNONMSGSRSV1>
        <INVSTMTMSGSRSV1>
          <INVSTMTTRNRS>
            <TRNUID>1001</TRNUID>
            <STATUS>
              <CODE>0</CODE>
              <SEVERITY>INFO</SEVERITY>
            </STATUS>
            <INVSTMTRS>
              <DTASOF>#{Time.now.utc.strftime('%Y%m%d%H%M%S')}
              <CURDEF>USD
      
              <INVACCTFROM>
                <BROKERID>Vanguard
                <ACCTID>CRYPTO
              </INVACCTFROM>
      
              <INVTRANLIST>
                <DTSTART>19000101000000</DTSTART>
                <DTEND>20990101000000</DTEND>

      #{rendered_transactions.join("\n").indent(10)}
              </INVTRANLIST>
              
              <SECLIST>

      #{render_securities.indent(10)}
              </SECLIST>
            </INVSTMTRS>
          </INVSTMTTRNRS>
        </INVSTMTMSGSRSV1>
      </OFX>
    EOF
  end
  
  def render_securities
    securities
      .map { |symbol, name|
        <<~EOF
          <SECINFO>
            <SECID>
              <UNIQUEID>#{format_security_symbol(symbol)}</UNIQUEID>
              <UNIQUEIDTYPE>OTHER</UNIQUEIDTYPE>
            </SECID>
            <SECNAME>#{format_security_name(name)}</SECNAME>
            <TICKER>#{format_security_symbol(symbol)}</TICKER>
          </SECINFO>
        EOF
      }
      .join("\n")
  end
  
  def render_sql
    puts "Writing position update queries"
    puts "-------------------------------"
    currency_to_transactions_map
      .map { |currency_id, transaction_ids|
        currency_id = currency_id.to_sym
        puts "#{'%-8s' % currency_id} - #{position_id_map[currency_id] || 'MISSING'}"
        next if transaction_ids.count.zero? || position_id_map[currency_id].nil?
        <<~SQL
          -- Update the ZPOSITION of #{currency_id} transactions
          UPDATE ZTRANSACTION
          SET ZPOSITION = #{position_id_map[currency_id]}
          WHERE ZFITRANSACTION IN (
            SELECT Z_PK
            FROM ZFITRANSACTION
            WHERE ZFITRANSACTIONID IN ('#{transaction_ids.join("', '")}')
          );
        SQL
      }
      .compact
      .join("\n")
  end
end

KoinlyTransformer
  .new
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page1.json'))['transactions'])
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page2.json'))['transactions'])
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page3.json'))['transactions'])
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page4.json'))['transactions'])
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page5.json'))['transactions'])
  .add_transactions(JSON.parse(File.read('./koinly-transactions/page6.json'))['transactions'])
  # .set_filter { |transaction| transaction['type'] == "exchange" && transaction['fee'].nil? }
  # .set_filter { |transaction| transaction['type'] == "exchange" && transaction.dig('fee', 'currency', 'type') == "crypto" }
  # .set_filter { |transaction| transaction['type'] == "exchange" && transaction.dig('fee', 'currency', 'type') == "fiat" }
  # .set_filter { |transaction| transaction['id'] == "ABC123" }
  .set_position_id_map({
    ADA: 193,
    AUDIO: 196,
    BAT: 199,
    BNB: 194,
    BTC: 190,
    DOGE: 201,
    DOT: 200,
    ERG: 204,
    ETH: 197,
    FET: 192,
    FLUX: 203,
    GRT: 212,
    LINK: 209,
    LPT: 195,
    LUNA: 198,
    MATIC: 208,
    ONE: 206,
    RVN: 202,
    SHIB: 211,
    USDC: 191,
    USDM: 213,
    USDT: 189,
    VET: 210,
    VTHO: 205,
    XLM: 207,
  })
  .render
