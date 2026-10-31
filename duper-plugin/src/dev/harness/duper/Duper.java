package dev.harness.duper;

import org.bukkit.Bukkit;
import org.bukkit.Material;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.inventory.InventoryClickEvent;
import org.bukkit.event.inventory.InventoryDragEvent;
import org.bukkit.inventory.Inventory;
import org.bukkit.inventory.InventoryHolder;
import org.bukkit.inventory.ItemStack;
import org.bukkit.inventory.meta.ItemMeta;
import org.bukkit.plugin.java.JavaPlugin;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class Duper extends JavaPlugin implements Listener {
    // Amount buttons: slot -> amount. Slot 4 shows the item being duped.
    private static final int[] SLOTS = {0, 1, 2, 3, 5, 6, 7, 8};
    private static final int[] AMOUNTS = {1, 4, 8, 16, 32, 64, 128, 256};
    private final Map<UUID, Long> last = new HashMap<>();

    /** Marks our GUI and remembers which item it copies. */
    private static final class Menu implements InventoryHolder {
        final ItemStack template;
        Inventory inv;
        Menu(ItemStack template) { this.template = template; }
        @Override public Inventory getInventory() { return inv; }
    }

    @Override
    public void onEnable() {
        saveDefaultConfig();
        getServer().getPluginManager().registerEvents(this, this);
    }

    @Override
    public boolean onCommand(CommandSender sender, Command cmd, String label, String[] args) {
        if (!(sender instanceof Player p)) {
            sender.sendMessage("Players only.");
            return true;
        }
        ItemStack hand = p.getInventory().getItemInMainHand();
        if (hand.getType() == Material.AIR) {
            p.sendMessage("§cHold the item you want to dupe, then type /dupe.");
            return true;
        }
        ItemStack template = hand.clone();
        template.setAmount(1);
        Menu menu = new Menu(template);
        Inventory inv = Bukkit.createInventory(menu, 9, "§8Duper - pick an amount");
        menu.inv = inv;
        inv.setItem(4, template.clone());
        for (int i = 0; i < SLOTS.length; i++) {
            inv.setItem(SLOTS[i], button(AMOUNTS[i]));
        }
        p.openInventory(inv);
        return true;
    }

    private static ItemStack button(int amount) {
        ItemStack b = new ItemStack(Material.LIME_STAINED_GLASS_PANE, Math.min(amount, 64));
        ItemMeta m = b.getItemMeta();
        m.setDisplayName("§aGive " + amount);
        m.setLore(List.of("§7Click to receive " + amount + " of this item"));
        b.setItemMeta(m);
        return b;
    }

    @EventHandler
    public void onClick(InventoryClickEvent e) {
        if (!(e.getInventory().getHolder() instanceof Menu menu)) return;
        e.setCancelled(true); // GUI items can never be taken
        if (!(e.getWhoClicked() instanceof Player p)) return;
        if (e.getClickedInventory() != e.getInventory()) return;
        int amount = 0;
        for (int i = 0; i < SLOTS.length; i++) {
            if (SLOTS[i] == e.getRawSlot()) amount = AMOUNTS[i];
        }
        if (amount == 0) return;

        long cd = getConfig().getLong("cooldown-seconds", 10) * 1000L;
        long now = System.currentTimeMillis();
        Long prev = last.get(p.getUniqueId());
        if (prev != null && now - prev < cd) {
            p.sendMessage("§cWait " + ((cd - (now - prev)) / 1000 + 1) + "s before duping again.");
            return;
        }
        last.put(p.getUniqueId(), now);

        // Hand out the amount in full stacks; anything that doesn't fit drops at the player's feet.
        int max = menu.template.getMaxStackSize();
        int left = amount;
        while (left > 0) {
            ItemStack stack = menu.template.clone();
            stack.setAmount(Math.min(left, max));
            left -= stack.getAmount();
            p.getInventory().addItem(stack).values()
                    .forEach(i -> p.getWorld().dropItemNaturally(p.getLocation(), i));
        }
        p.closeInventory();
        p.sendMessage("§aDuped §f" + amount + "x " + menu.template.getType().name().toLowerCase() + "§a!");
    }

    @EventHandler
    public void onDrag(InventoryDragEvent e) {
        if (e.getInventory().getHolder() instanceof Menu) e.setCancelled(true);
    }
}
