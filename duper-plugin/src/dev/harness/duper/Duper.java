package dev.harness.duper;

import org.bukkit.Material;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.entity.Player;
import org.bukkit.inventory.ItemStack;
import org.bukkit.plugin.java.JavaPlugin;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

public final class Duper extends JavaPlugin {
    private final Map<UUID, Long> last = new HashMap<>();

    @Override
    public void onEnable() {
        saveDefaultConfig();
    }

    @Override
    public boolean onCommand(CommandSender sender, Command cmd, String label, String[] args) {
        if (!(sender instanceof Player p)) {
            sender.sendMessage("Players only.");
            return true;
        }
        ItemStack hand = p.getInventory().getItemInMainHand();
        if (hand.getType() == Material.AIR) {
            p.sendMessage("§cHold an item to dupe.");
            return true;
        }
        long cd = getConfig().getLong("cooldown-seconds", 10) * 1000L;
        long now = System.currentTimeMillis();
        Long prev = last.get(p.getUniqueId());
        if (prev != null && now - prev < cd) {
            p.sendMessage("§cWait " + ((cd - (now - prev)) / 1000 + 1) + "s before duping again.");
            return true;
        }
        last.put(p.getUniqueId(), now);
        // Give an exact copy (keeps enchants, names, shulker contents); drop overflow at feet.
        p.getInventory().addItem(hand.clone()).values()
                .forEach(i -> p.getWorld().dropItemNaturally(p.getLocation(), i));
        p.sendMessage("§aDuped §f" + hand.getAmount() + "x " + hand.getType().name().toLowerCase() + "§a!");
        return true;
    }
}
