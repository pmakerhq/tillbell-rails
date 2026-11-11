RSpec.describe "Paywall locales" do
  # Every translation has the same keys as English, so no text falls back by accident.
  it "ships complete translations" do
    keys = ->(hash, prefix = nil) { hash.flat_map { |key, value| value.is_a?(Hash) ? keys.(value, [ prefix, key ].compact.join(".")) : [ [ prefix, key ].compact.join(".") ] } }
    english = keys.(I18n.t("tillbell.paywall", locale: :en))

    %i[fr es de].each do |locale|
      expect(keys.(I18n.t("tillbell.paywall", locale: locale))).to match_array(english)
    end
  end
end
