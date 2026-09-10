-- Map App Store product identifiers to Albus tiers.
--
-- **Without a row here, no purchase can ever grant anything.**
-- `apply_subscription_state` resolves the tier by looking the product id up in
-- this table and returns `unknown_product` when it finds nothing:
--
--     select sp.tier into v_tier
--       from public.subscription_products sp
--      where sp.product_id = v_product and sp.active;
--     ...
--     if v_tier is null then return 'unknown_product'; end if;
--
-- The table was empty in production, so every RevenueCat webhook would have
-- taken that branch. Apple would have charged the student and Albus would have
-- left them on Free, with the webhook returning 200 and nothing looking broken.
-- Failing closed is the right instinct for money; failing closed silently, with
-- the charge already made, is not.
--
-- **These identifiers must match App Store Connect exactly.** They follow the
-- bundle id (`com.felipegutierrez.albus`) by convention. If different ones are
-- created in App Store Connect, change them here in the same PR — a mismatch
-- reproduces the identical silent failure this migration exists to remove.
--
-- Retirement is `active = false`, never a delete: `apply_subscription_state`
-- deliberately falls back to the stored mapping for an existing subscriber, so
-- pulling a product from sale stops new grants without cutting off anyone who
-- already paid. Deleting the row would break that fallback.

insert into public.subscription_products (product_id, tier, active) values
  ('com.felipegutierrez.albus.plus.monthly', 'plus', true),
  ('com.felipegutierrez.albus.plus.annual',  'plus', true),
  ('com.felipegutierrez.albus.pro.monthly',  'pro',  true),
  ('com.felipegutierrez.albus.pro.annual',   'pro',  true)
on conflict (product_id) do update
  set tier = excluded.tier,
      active = excluded.active;

-- Every tier named above has to exist in `plans`, or the entitlement join in
-- `apply_subscription_state` silently drops the transaction and the student
-- lands back on Free with a valid receipt.
do $$
declare
  v_orphans text[];
begin
  select array_agg(distinct sp.tier order by sp.tier) into v_orphans
    from public.subscription_products sp
   where not exists (select 1 from public.plans p where p.tier = sp.tier);

  if v_orphans is not null then
    raise exception 'subscription_products names tier(s) with no plans row: %', v_orphans;
  end if;
end $$;
