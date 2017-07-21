# This class models both a Hotel Block and a Hotel Reservation.
# A Teammanager can reserve a block of rooms. If he wants to block 100 rooms, the system will
# create 100 HotelReservation rows in the database with team_id set to the team he's blocking the rooms for.
# To make an actual reservation, the HotelReservation row much have an associated Order object that is in the state "reserved" or "paid"
class HotelReservation < ActiveRecord::Base
  include PreventChange
  raise_on_change_if(Exceptions::HasReservationsError, only_on: :destroy){ self.hotel_reservation_code.present? }

  MAX_BLOCK_DURATION = 7.days
  self.inheritance_column = :child_class

  belongs_to :hotel_quote_rate, touch: true
  belongs_to :hotel #strictly not necessary but simplifies queries and understanding
  belongs_to :event
  belongs_to :event_venue 
  belongs_to :team
  belongs_to :individual, :class_name => 'User'
  belongs_to :order

  scope :joins_hotel_quote, -> { joins(hotel_quote_rate: {hotel_quote_qtys: :hotel_quote}) }
  scope :hotel_quotes_accepted, -> { joins_hotel_quote.where('hotel_quotes.status' => HotelQuote::STATUS_ACCEPTED) }
  scope :for_hotel_quote, ->(hotel_quote) { joins_hotel_quote.where('hotel_quotes.id' => hotel_quote) }
  scope :for_hotel_quote_rate_group, ->(hotel_quote_rate_group) { joins(:hotel_quote_group).where('hotel_quote_rate.hotel_quote_group_id' => hotel_quote_rate_group) }
  scope :for_year, ->(year) { joins(hotel_quote_rate: :hotel_quote_qtys).where("EXTRACT(YEAR FROM hotel_quote_qtys.night_at) = ?", year) }
  scope :for_year_month, ->(year, month) { joins(hotel_quote_rate: :hotel_quote_qtys).where("EXTRACT(YEAR FROM hotel_quote_qtys.night_at) = ? AND EXTRACT(MONTH FROM hotel_quote_qtys.night_at) = ?", year, month) }
  scope :for_hotel_quote_rate_and_team, ->(hotel_quote_rate, team, event) { for_hotel_quote_rate(hotel_quote_rate).for_team_if_event_competition(team, event) }
  scope :for_hotel_quote_rate, ->(hotel_quote_rate) { hotel_quotes_accepted.where('hotel_reservations.hotel_quote_rate_id' => hotel_quote_rate) }
  scope :for_hotel_quote_qty, ->(hotel_quote_qty) { hotel_quotes_accepted.joins(hotel_quote_rate: :hotel_quote_qtys).where('hotel_quote_qtys.id' => hotel_quote_qty) }
  scope :for_hotel_room_type, ->(hotel_room_type) { joins(hotel_quote_rate: {hotel_quote_qtys: :hotel_room_type}).where('hotel_room_types.id' => hotel_room_type) }
  scope :for_day, ->(date) { hotel_quotes_accepted.joins(hotel_quote_rate: :hotel_quote_qtys).where('date(hotel_quote_qtys.night_at) = date(?)', date) }
  scope :for_event, ->(event) { where("hotel_reservations.event_id" => event) }
  scope :for_event_venue, ->(event_venue) { where("hotel_reservations.event_venue_id" => event_venue) }
  scope :for_hotel, ->(hotel) { where("hotel_reservations.hotel_id" => hotel) }
  scope :for_team, ->(team) { where('hotel_reservations.team_id' => team) }
  scope :for_team_if_event_competition, ->(team, event) {
    if team && ClassUtil.is_a_with_decorator_compensate(event, EventCompetition)
      scoped = for_team(team)
    end
    scoped
  }
  scope :for_individual, ->(individual) { where('hotel_reservations.individual_id' => individual) }
  scope :for_order, ->(order) { where('hotel_reservations.order_id' => order) }
  scope :complete_without_join, -> { where('hotel_reservations.order_id IS NOT NULL AND orders.placed_at IS NOT NULL') }
  scope :complete, -> { joins(:order).complete_without_join } #inner join
  scope :incomplete, -> { joins('LEFT OUTER JOIN orders ON orders.id=hotel_reservations.order_id').incomplete_without_join }
  scope :incomplete_without_join, -> { hotel_quotes_accepted.where('order_id IS NULL OR orders.placed_at IS NULL') }
  scope :placed_after, ->(ts) { where("orders.placed_at > ?", ts) }
  scope :unreserved_hotel_rooms, ->(event, team) { for_event(event).incomplete.for_team_if_event_competition(team, event) }
  scope :for_quick_cancellation_period, ->(active) { joins(:order).where("NOW() #{ active ? '<' : '>' } orders.quick_cancellation_expire_at") }
  scope :for_credit_card, ->(credit_card) { joins(order: :credit_card).where('credit_cards.id' => credit_card) }
  scope :for_hotel_reservation_code, ->(hotel_reservation_code) { where('hotel_reservations.hotel_reservation_code' => hotel_reservation_code) }
  scope :without_hotel_code, ->() { complete.where('hotel_reservations.hotel_reservation_code IS NULL') }
  scope :without_hotel_code_after_cancellation_period, ->() { without_hotel_code.for_quick_cancellation_period(false) }

  # attr_accessible :team, :hotel_quote_rate
  validates :hotel, :event, :event_venue, :hotel_quote_rate, :presence => true
  after_commit :touch_hotel_quote
  before_create :set_block_expirest_at
  after_destroy :save_historical_destroy
  after_save :save_historical_save
  
  def block_expired?
    [block_expires_at || Time.at(0), hotel_quote.block_expire_at].min < Time.now
  end

  def hotel_quote
    hotel_quote_rate.hotel_quote
  end

  def self.reservations_exists_for_event(event, hotel)
    HotelReservation.for_event(event).for_hotel(hotel).exists?
  end

  def self.reservations_exists_for_event_venue(event_venue, hotel)
    HotelReservation.for_event_venue(event_venue).for_hotel(hotel).exists?
  end

  def cancellable?
    return true unless order
    order.in_quick_cancellation_period?
  end

  #returns nil if not expiring
  def hold_expires_at
    return nil if self.order_id.present?
    [self.block_expires_at, hotel_quote.block_expire_at].min
  end

  def individual_cancellation_cutoff_time
    first_night = hotel_quote_rate.hotel_quote_qtys.map{|y| y.night_at}.min
    ret = first_night - hotel_quote.individual_cancel_notice
    ret=ret.noon+4.hours
    ret
  end

  private

  def touch_hotel_quote
    HotelQuote.for_hotel_quote_rate(hotel_quote_rate).distinct.each{|x| x.touch}
  end

  def set_block_expirest_at
    self.block_expires_at = ((event_venue.block_duration_hours || event.block_duration_hours).try(:hours) || HotelReservation::MAX_BLOCK_DURATION).from_now
  end

  def save_historical_destroy
    HistoricalHotelReservation.create_from_hotel_reservation(self, 'destroy')
  end

  def save_historical_save
    HistoricalHotelReservation.create_from_hotel_reservation(self, 'save')
  end
  
end
