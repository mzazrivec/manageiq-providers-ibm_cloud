class ManageIQ::Providers::IbmCloud::Inventory < ManageIQ::Providers::Inventory
  require_nested :Collector
  require_nested :Parser
  require_nested :Persister
end
