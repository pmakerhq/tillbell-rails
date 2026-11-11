class User < ApplicationRecord
  pay_customer
  include Tillbell::Owner
end
